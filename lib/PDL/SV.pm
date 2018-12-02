package PDL::SV;

use 5.010;
use strict;
use warnings;

use PDL::Lite;
use PDL::Core qw(pdl);
use PDL::Primitive qw(which whichND);
use Data::Rmap qw(rmap_array);
use Safe::Isa;
use Storable qw(dclone);
use List::AllUtils ();

use parent 'PDL';

use Role::Tiny::With;
with qw(PDL::Role::Stringifiable);

use Devel::OverloadInfo qw(overload_op_info);

my $super_dotassign;

BEGIN {
    my $overload_info_dotassign = overload_op_info( 'PDL', '.=' );
    $super_dotassign = $overload_info_dotassign->{code};
}

# TODO: fix below as '.='
use overload
  '==' => \&_eq,
  'eq' => \&_eq,
  '.=' => sub {
    my ( $self, $other, $swap ) = @_;

    unless ( $other->$_DOES('PDL::SV') ) {
        return $super_dotassign->( $self, $other, $swap );
    }

    my $internal = $self->_internal;
    for my $i ( 0 .. $other->dim(0) - 1 ) {
        my $idx = PDL::Core::at( $self, $i );
        $internal->[$idx] = $other->at($i);
    }
    return $self;
  },
  fallback => 1;

# after stringifiable role is added, the string method will exist
eval q{
	use overload ( '""'   =>  \&PDL::SV::string );
};

sub _internal {
    my ( $self, $val ) = @_;
    if ( defined $val ) {
        $self->{_internal} = $val;
    }
    return $self->{_internal};
}

sub new {
    my ( $class, @args ) = @_;
    my $data = shift @args;    # first arg

    my ($faked_data) = rmap_array {
        ( ref( $_->[0] ) eq 'ARRAY' ) ? [ $_[0]->recurse() ] : [ (0) x @$_ ]
    }
    $data;

    my $self = $class->initialize();
    my $pdl  = $self->{PDL};
    $pdl .= PDL::Core::indx($faked_data);
    $pdl .= PDL->sequence( $self->dims );

    my $nelem    = $self->nelem;
    my $internal = $self->_internal;
    for my $idx ( 0 .. $nelem - 1 ) {
        my @where = reverse $self->one2nd($idx);
        $internal->[$idx] = $self->_array_get( $data, \@where );
    }

    $self;
}

sub initialize {
    my ($class) = @_;
    return bless( { PDL => PDL::Core::null, _internal => [] }, $class );
}

# code modified from <https://metacpan.org/pod/Hash::Path>
sub _array_get {
    my ( $self, $array, $indices ) = @_;
    return $array unless scalar @$indices;
    my $return_value = $array->[ $indices->[0] ];
    for ( 1 .. $#$indices ) {
        $return_value = $return_value->[ $indices->[$_] ];
    }
    return $return_value;
}

sub _array_set {
    my ( $self, $array, $indices, $val ) = @_;
    return unless scalar @$indices;

    my $subarray = $array;
    for ( 0 .. $#$indices - 1 ) {
        $subarray = $subarray->[ $indices->[$_] ];
    }
    $subarray->[ $indices->[-1] ] = $val;
}

for my $method (qw(slice dice)) {
    no strict 'refs';
    *{$method} = sub : lvalue {
        my $self = shift;

        my $super_method = "SUPER::$method";
        my $new = $self->$super_method(@_);
        $new->_internal( $self->_internal );
        return $new;
    }
}

sub uniq {
    my $self  = shift;
    my $class = ref($self);

    my $uniq = [ List::AllUtils::uniq( @{ $self->_internal } ) ];
    return $class->new($uniq);
}

#around qw(sever) => sub {
#	# TODO
#	# clone the contents of _internal
#	# renumber the elements
#};

sub at {
    my $self = shift;

    my $idx = $self->SUPER::at(@_);
    return 'BAD' if $idx eq 'BAD';
    return $self->_internal->[$idx];
}

sub unpdl {
    my $self = shift;

    my $data     = $self->{PDL}->unpdl;
    my $internal = $self->_internal;
    my $f =
      $self->badflag
      ? sub { $_ = ( $_ eq 'BAD' ? 'BAD' : $internal->[$_] ); }
      : sub { $_ = $internal->[$_] };
    Data::Rmap::rmap_scalar { $f->($_) } $data;
    return $data;
}

#TODO: reimplement to reduce memory usage
sub copy {
    my ($self) = @_;

    my $new = PDL::SV->new( [] );
    $new->{PDL} = PDL->sequence( $self->dims );
    if ( $self->badflag ) {
        $new->{PDL} = $new->{PDL}->setbadif( $self->isbad );
    }
    $new->_internal( [ map { $_ // 'BAD' } @{ $self->_effective_internal } ] );
    return $new;
}

sub inplace {
    my $self = shift;
    $self->{PDL}->inplace(@_);
    return $self;
}

sub _call_on_pdl {
    my ($method) = @_;

    return sub {
        my $self = shift;
        return $self->{PDL}->$method(@_);
    };
}

for my $method (qw(isbad isgood)) {
    no strict 'refs';
    *{$method} = _call_on_pdl($method);
}

sub setbadif {
    my $self = shift;

    my $new = $self->copy;
    $new->{PDL} = $new->{PDL}->setbadif(@_);
    return $new;
}

=method setbadtoval

Cannot be run inplace.

=cut

sub setbadtoval {
    my $self = shift;
    my ($val) = @_;

    my $class = ref($self);

    my $data = $self->unpdl;
    if ( $self->badflag ) {
        my $isbad = $self->isbad;
        for my $idx ( which($isbad)->list ) {
            my @where = reverse $self->one2nd($idx);
            $self->_array_set( $data, \@where, $val );
        }
    }
    return $class->new($data);
}

=method match_regexp

    match_regexp($pattern)

Match against a plain a regular expression.
Returns a piddle of the same dimension.

=cut

sub match_regexp {
    my ( $self, $regexp ) = @_;

    my @matches = map { $_ =~ $regexp ? 1 : 0 } @{ $self->_internal };
    my $p = pdl( \@matches )->reshape( $self->dims );
    if ( $self->badflag ) {
        $p = $p->setbadif( $self->isbad );
    }
    return $p;
}

sub _effective_internal {
    my ($self) = @_;

    my $internal = $self->_internal;
    my $rslt =
      [ map { $_ eq 'BAD' ? undef : $internal->[$_] } ( $self->{PDL}->list ) ];
    return $rslt;
}

sub _eq {
    my ( $self, $other, $swap ) = @_;

    # check dimensions
    {
        no warnings qw(void);

        # this would die if they are not same
        $self->{PDL}->shape == $other->{PDL}->shape;
    }

    my $self_effective_internal  = $self->_effective_internal;
    my $other_effective_internal = $other->_effective_internal;
    my @is_equal                 = List::AllUtils::pairwise {
        defined $a and defined $b and $a eq $b
    }
    @$self_effective_internal, @$other_effective_internal;

    my $rslt = PDL::Core::pdl( \@is_equal )->reshape( $self->dims );
    if ( $self->badflag or $other->badflag ) {
        $rslt = $rslt->setbadif( $self->isbad | $other->isbad );
    }
    return $rslt;
}

sub element_stringify_max_width {
    my ( $self, $element ) = @_;
    my @where   = @{ $self->uniq->SUPER::unpdl };
    my @which   = @{ $self->_internal }[@where];
    my @lengths = map { length $_ } @which;
    List::AllUtils::max(@lengths);
}

1;
