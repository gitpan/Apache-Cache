package Apache::Cache;
#$Id: Cache.pm,v 1.10 2001/08/08 15:55:03 rs Exp $

=pod

=head1 NAME

Apache::Cache - Cache data accessible between Apache childrens

=head1 SYNOPSIS

    use Apache::Cache qw(:all);

    my $cache = new Apache::Cache(cachename=>"dbcache", default_expires_in=>"5 minutes");

    my $value = get_data('value_45');
    $cache->set('value_45'=>$value);
    print STDERR "can't save data in the cache" if($cache->status eq FAILURE);

1 minute past

    my $value = $cache->get('value_45');
    # $value equal 'data'

10 minutes past

    my $value = $cache->get('value_45');
    # $value equal 'undef()'
    if($cache->status eq EXPIRED)
    {
        # update value
        $cache->lock(LOCK_EX); # optional
        $value = get_data('value_45');
        $cache->set('value_45' => $value);
        $cache->unlock;
    }
    elsif($cache->status eq FAILURE)
    {
        # don't use cache, cache maybe busy by another child
        $value = get_data('value_45');
    }

=head1 DESCRIPTION

This module allows you to cache data easily through shared memory. Whithin the framework 
of an apache/mod_perl use, this cache is accessible from any child process. The data 
validity is managed in the Cache::Cache model, but as well based on time than on size 
or number of keys.

=head1 USAGE

under construction

=cut

BEGIN
{
    use strict;
    use 5.005;
    use Carp;
    use Apache::SharedMem qw(:all);
    use Time::ParseDate;

    use base qw(Apache::SharedMem Exporter);

    %Apache::Cache::EXPORT_TAGS = 
    (
        all       => [qw(EXPIRED SUCCESS FAILURE EXPIRES_NOW EXPIRES_NEVER)],
        expires   => [qw(EXPIRES_NOW EXPIRES_NEVER)],
        status    => [qw(SUCCESS FAILURE EXPIRED)],
    );
    @Apache::Cache::EXPORT_OK   = @{$Apache::Cache::EXPORT_TAGS{'all'}};

    use constant EXPIRED        => -1;
    use constant EXPIRES_NOW    => 1;
    use constant EXPIRES_NEVER  => 0;

    $Apache::Cache::VERSION     = '0.03';
}

=pod

=head1 METHODS

=head2 new  (cachename=> 'cachename', default_expires_in=> '1 second', max_keys=> 50, max_size=> 1_000)

=cut

sub new
{
    my $pkg     = shift;
    my $class   = ref($pkg) || $pkg;

    my $options = 
    {
        namespace           => (caller())[0],
        cachename           => undef(),
        default_expires_in  => EXPIRES_NEVER,
        max_keys            => undef(),
        max_size            => undef(),
    };

    croak("odd number of arguments for object construction")
      if(@_ % 2);
    my @del;
    for(my $x = 0; $x < $#_; $x += 2)
    {
        if(exists($options->{lc($_[$x])}))
        {
            $options->{lc($_[$x])} = $_[($x + 1)];
            splice(@_, $x, 2);
            $x -= 2;
        }
    }

    foreach my $name (qw(cachename))
    { 
        croak("$pkg object creation missing $name parameter.")
          unless(defined($options->{$name}) && $options->{$name} ne '');
    }

    my $self = $class->SUPER::new(@_, namespace=>$options->{namespace});
    return(undef()) unless(defined($self));
    $self->{cache_options} = $options;

    unless($self->SUPER::exists($options->{cachename}, NOWAIT))
    {
        return(undef()) if($self->SUPER::status eq FAILURE);
        my $cache_registry =
        {
            _cache_metadata => 
            {
                timestamps  => {},
                queue       => [],
            }
        };
        $self->SUPER::set($options->{cachename}=>$cache_registry, NOWAIT);
        return(undef()) if($self->SUPER::status eq FAILURE);
    }

    bless($self, $class);
    return($self);
}

=pod

=head2 set (key => value, [timeout])

$cache->set(mykey=>'the data to cache', '15 minutes');
if($cache->status eq FAILURE)
{
    warn("can't save data to cache: $cache->error");
}

key (required): key to set

value (required): value to set

timeout (optional): can be on of EXPIRES_NOW, EXPIRES_NEVER (need import of :expires tag),
or a time string like "10 minutes", "May 5 2010 01:30:00"... (see L<Time::ParseDate>).

On failure this method return C<undef()> and place status method to FAILURE.

status : FAILURE SUCCESS

=cut

sub set
{
    my $self  = shift;
    my $key   = defined($_[0]) && $_[0] ne '' ? shift : croak(defined($_[0]) ? 'Not enough arguments for set method' : 'Invalid argument "" for set method');
    my $value = defined($_[0]) ? shift : croak('Not enough arguments for set method');
    my $time  = defined($_[0]) ? shift : $self->{cache_options}->{default_expires_in};
    croak('Too many arguments for set method') if(@_);
    $self->_unset_error;
    $self->_debug;

    if($key eq '_cache_metadata')
    {
        $self->_set_status(FAILURE);
        $self->_set_error("$key: reserved key");
        return(undef());
    }

    my $timeout;
    if($time)
    {
        if($time =~ m/\D/)
        {
            $timeout = parsedate($time, TIMEFIRST=>1, PREFER_FUTURE=>1);
            unless(defined $timeout)
            {
                $self->_set_error("error on timeout string decoding. time string requested: $time");
                $self->_set_status(FAILURE);
                return(undef());
            }
        }
        else
        {
            $timeout = time() + $time;
        }
    }
    else
    {
        $timeout = EXPIRES_NEVER;
    }

    $self->_debug('timeout is set for expires in ', ($timeout - time()), ' seconds');

    if($self->lock(LOCK_EX|LOCK_NB))
    {
        my $data = $self->_get_datas || return(undef());
        $data->{$key} = $value;
        $data->{'_cache_metadata'}->{'timestamps'}->{$key} = $timeout;
        push(@{$data->{'_cache_metadata'}->{'queue'}}, $key);

        $self->_check_keys($data);
        $self->_check_size($data);

        $self->SUPER::set($self->{cache_options}->{cachename}=>$data, NOWAIT);
        return(undef()) if($self->status eq FAILURE);

        return($value);
    }
    else
    {
        $self->_set_error('can\'t get exclusive lock for "set" method');
        $self->_set_status(FAILURE);
        return(undef());
    }
}

sub get
{
    if(@_ != 2)
    {
        confess('Apache::Cache: Too many arguments for "get" method') if(@_ > 2);
        confess('Apache::Cache: Not enough arguments for "get" method') if(@_ < 2);
    }
    my($self, $key) = @_;
    
    my $data    = $self->_get_datas || return(undef());
    unless(exists $data->{$key})
    {
        $self->_set_status(EXPIRED);
        return(undef());
    }
    my $value   = $data->{$key};
    my $timeout = $data->{_cache_metadata}->{timestamps}->{$key};

    if(!defined $timeout || ($timeout != EXPIRES_NEVER && $timeout <= time()))
    {
        $self->_set_error("data was expired");
        $self->_set_status(EXPIRED);
        $self->delete($key);
        return(undef());
    }
    else
    {
        $self->_set_status(SUCCESS);
        return($value);
    }
}

sub delete
{
    if(@_ != 2)
    {
        confess('Apache::Cache: Too many arguments for "delete" method') if(@_ > 2);
        confess('Apache::Cache: Not enough arguments for "delete" method') if(@_ < 2);
    }
    my($self, $key) = @_;

    my $rv;
    if($self->lock(LOCK_EX|LOCK_NB))
    {
        my $data = $self->_get_datas || return(undef());
        if(exists $data->{$key})
        {
            $rv = delete($data->{$key});
            delete($data->{_cache_metadata}->{timestamps}->{$key});
            $data->{_cache_metadata}->{queue} = \@{grep($_ ne $key, @{$data->{_cache_metadata}->{queue}})};
            $self->SUPER::set($self->{cache_options}->{cachename}=>$data);
            return(undef()) if($self->status eq FAILURE);
        }
        $self->unlock;
    }
    return($rv);
}

sub _check_keys
{
    my($self, $data) = @_;

    my $max_keys = $self->{cache_options}->{max_keys};
    return() unless(defined $max_keys && $max_keys);
    my $metadata = $data->{_cache_metadata};
    my $nkeys    = @{$metadata->{queue}};
    $self->_debug("cache have now $nkeys keys");
    if($nkeys > $max_keys)
    {
        my $time = time();
        my $nkeys_target = int($max_keys - ($max_keys/10));
        $self->_debug("cache is full, max_key: $max_keys, current key counts: $nkeys, cleaning ", $nkeys - $nkeys_target, " keys");
        # cheching for expired datas
        for(my $i = $nkeys - 1; $i >= 0; $i--)
        {
            if($metadata->{timestamps}->{$metadata->{queue}->[$i]} > $time)
            {
                my $key = $metadata->{queue}->[$i];
                delete($data->{$key});
                delete($metadata->{timestamps}->{$key});
                $metadata->{queue} = \@{grep($_ ne $key, @{$metadata->{queue}})};
                last if(--$nkeys <= $nkeys_target);
            }
        }
        if($nkeys > $max_keys)
        {
            # splice of delete candidates
            my @key2del = splice(@{$metadata->{queue}}, 0, ($nkeys - $nkeys_target));
            delete(@$data{@key2del});
            delete(@{$metadata->{timestamps}}{@key2del});
        }
    }
}

sub _check_size
{
    my($self, $data) = @_;

    my $max_size = $self->{cache_options}->{max_keys};
    return() unless(defined $max_size && $max_size);
}

sub _get_datas
{
    my $self = shift;
    
    my $data = $self->SUPER::get($self->{cache_options}->{cachename}, NOWAIT);
    if($self->status eq FAILURE)
    {
        $self->_set_error("can't get the cacheroot: ", $self->error);
        return(undef());
    }

    croak("Apache::Cache: wrong data format.")
      if(ref($data) ne 'HASH' || ! exists $data->{_cache_metadata});
    
    return($data);
}

1;
