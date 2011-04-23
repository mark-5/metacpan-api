package MetaCPAN::Script::Latest;

use feature qw(say);
use Moose;
use MooseX::Aliases;
with 'MooseX::Getopt';
use Log::Contextual qw( :log );
with 'MetaCPAN::Role::Common';

has dry_run => ( is => 'ro', isa => 'Bool', default => 0 );
has distribution => ( is => 'ro', isa => 'Str' );

sub run {
    my $self = shift;
    my $es   = $self->es;
    log_info { "Dry run: updates will not be written to ES" }
      if ( $self->dry_run );
    $es->refresh_index();
    my $query =
      $self->distribution
      ? { term => { distribution => lc($self->distribution) } }
      : { match_all => {} };
    my $search = { index => $self->index->name,
                   type  => 'release',
                   query => $query,
                   size  => 100,
                   from  => 0,
                   sort  => ['distribution',
                             { maturity => { reverse => \1 } },
                             { date     => { reverse => \1 } }
                   ], };

    my $dist = '';
    my $rs   = $es->search(%$search);
    while ( my $row = shift @{ $rs->{hits}->{hits} } ) {
        if ( $dist ne $row->{_source}->{distribution} ) {
            $dist = $row->{_source}->{distribution};
            goto SCROLL if ( $row->{_source}->{status} eq 'latest' );
            log_info { "Upgrading $row->{_source}->{name} to latest" };

            for (qw(file dependency)) {
                log_debug { "Upgrading $_" };
                $self->reindex( $_, $row->{_id}, 'latest' );
            }
            next if ( $self->dry_run );
            $es->index( index => $self->index->name,
                        type  => 'release',
                        id    => $row->{_id},
                        data  => { %{ $row->{_source} }, status => 'latest' } );
        } elsif ( $row->{_source}->{status} eq 'latest' ) {
            log_info { "Downgrading $row->{_source}->{name} to cpan" };

            for (qw(file dependency)) {
                log_debug { "Downgrading $_" };
                $self->reindex( $_, $row->{_id}, 'cpan' );
            }
            next if ( $self->dry_run );
            $es->index( index => $self->index->name,
                        type  => 'release',
                        id    => $row->{_id},
                        data  => { %{ $row->{_source} }, status => 'cpan' } );
        # }
        SCROLL:
        unless ( @{ $rs->{hits}->{hits} } ) {
            $search = { %$search, from => $search->{from} + $search->{size} };
            $rs = $es->search($search);
        }
    }
}

sub reindex {
    my ( $self, $type, $release, $status ) = @_;
    my $es = $self->es;
    my $search = { index => $self->index->name,
                   type  => $type,
                   query => { term => { release => $release } },
                   # sort  => ['_id'],
                   size  => 30,
                   from  => 0, };
    my $rs = $es->search(%$search);
    while ( my $row = shift @{ $rs->{hits}->{hits} } ) {
        log_debug { $status eq 'latest' ? "Upgrading " : "Downgrading ",
          $type, " ", $row->{_source}->{name} || '' };
        $es->index( index => $self->index->name,
                    type  => $type,
                    id    => $row->{_id},
                    data  => { %{ $row->{_source} }, status => $status }
        ) unless ( $self->dry_run );
        unless ( @{ $rs->{hits}->{hits} } ) {
            $search = { %$search, from => $search->{from} + $search->{size} };
            $rs = $es->search($search);
        }
    }

}

__PACKAGE__->meta->make_immutable;

__END__

=head1 SYNOPSIS

 # bin/metacpan latest

 # bin/metacpan latest --dry_run
 
=head1 DESCRIPTION

After importing releases from cpan, this script will set the status
to latest on the most recent release, its files and dependencies.
It also makes sure that there is only one latest release per distribution.
