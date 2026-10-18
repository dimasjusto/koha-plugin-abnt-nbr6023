package Koha::Plugin::BR::NBR6023::Controller;

# Controlador da rota REST do plugin.

use Modern::Perl;
use utf8;
use Mojo::Base 'Mojolicious::Controller';
use Try::Tiny;

use C4::Context;
use Koha::Biblios;
use Koha::Plugin::BR::NBR6023;
use Koha::Plugin::BR::NBR6023::Formatter;

sub get {
    my $c = shift->openapi->valid_input or return;

    my $biblio_id = $c->param('biblio_id');
    my $mode      = $c->param('mode');

    return try {
        my $biblio = Koha::Biblios->find($biblio_id);
        return $c->render( status => 404, openapi => { error => 'Registro não encontrado.' } )
          unless $biblio;

        my $record = $biblio->metadata->record;
        my $user   = $c->stash('koha.user');

        # Registro suprimido no OPAC (942 $n) não é exposto a quem não é da equipe
        my $staff = $user && $user->has_permission( { catalogue => 1 } );
        if ( !$staff ) {
            if ( C4::Context->preference('OpacSuppression') ) {
                my $n = $record->subfield( '942', 'n' );
                return $c->render( status => 404, openapi => { error => 'Registro não encontrado.' } )
                  if $n && $n eq '1';
            }
        }

        my $plugin = Koha::Plugin::BR::NBR6023->new;
        my $f      = $plugin->formatter( mode => $mode, parent_resolver => _resolver($biblio) );
        my $r      = $f->format($record);

        return $c->render(
            status  => 200,
            openapi => {
                biblio_id => $biblio_id + 0,
                mode      => $f->{mode},
                type      => $r->{type},
                html      => Koha::Plugin::BR::NBR6023::Formatter->to_html( $r->{segments} ),
                text      => Koha::Plugin::BR::NBR6023::Formatter->to_text( $r->{segments} ),
                warnings  => $r->{warnings},
            }
        );
    }
    catch {
        $c->app->log->error("Plugin ABNT: $_");
        return $c->render( status => 500, openapi => { error => 'Erro ao gerar a referência.' } );
    };
}

# Resolve o registro-pai do 773 $w:
#   1. Koha::Biblio->get_marc_host (001/003, MARCOrgCode, como o próprio Koha liga analíticas)
#   2. busca pelo número no 035 (números antigos de sistemas migrados, ex.: Aleph)
#   3. busca pelo número no 001
sub _resolver {
    my ($biblio) = @_;
    my $host_tried;
    my %cache;
    return sub {
        my ($w) = @_;
        return $cache{$w} if exists $cache{$w};
        if ( !$host_tried ) {
            $host_tried = 1;
            my $host = try { scalar $biblio->get_marc_host } catch { undef };
            if ($host) {
                my $rec = try { $host->metadata->record } catch { undef };
                return $cache{$w} = $rec if $rec;
            }
        }
        return $cache{$w} = _search_one("Other-control-number,ext=\"$w\"")
          // _search_one("Control-number,ext=\"$w\"");
    };
}

sub _search_one {
    my ($query) = @_;
    return try {
        require Koha::SearchEngine;
        require Koha::SearchEngine::Search;
        my $searcher = Koha::SearchEngine::Search->new( { index => $Koha::SearchEngine::BIBLIOS_INDEX } );
        my ( $err, $results, $total ) = $searcher->simple_search_compat( $query, 0, 1 );
        return undef if $err || !$total || !$results || !@$results;
        my $r = $results->[0];
        return $r if ref $r && $r->isa('MARC::Record');    # Elasticsearch
        require C4::Search;
        return C4::Search::new_record_from_zebra( 'biblioserver', $r );    # Zebra
    }
    catch { undef };
}

1;
