package Koha::Plugin::BR::NBR6023;

# Plugin Koha: referência ABNT NBR 6023:2025 do registro bibliográfico.
# Botão "Referência ABNT" no OPAC e na intranet, rota REST e página de configuração.

use Modern::Perl;
use utf8;
use base qw(Koha::Plugins::Base);

use JSON qw(decode_json encode_json);
use Koha::Plugin::BR::NBR6023::Formatter;

our $VERSION = '0.2.1';

our $metadata = {
    name            => 'Referência ABNT (NBR 6023)',
    author          => 'Sebastião Dimas Justo da Silva',
    date_authored   => '2026-10-18',
    date_updated    => '2026-10-18',
    minimum_version => '24.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Gera a referência bibliográfica ABNT NBR 6023:2025 do registro, '
      . 'a partir da catalogação MARC21 (RDA ou AACR2), no OPAC e na intranet.',
};

# Valores padrão da configuração
our %DEFAULTS = (
    label                  => 'Referência ABNT',
    show_opac              => 1,
    opac_in_cite           => 1,
    cite_label             => 'ABNT',
    show_intranet          => 1,
    mode_default           => 'essencial',
    allow_mode_toggle      => 1,
    et_al_threshold        => 4,
    online_policy          => 'recurso',
    uniform_title_brackets => 1,
    editor_default_abbrev  => 'org.',
    extra_place_phrases    => '',
    extra_publisher_phrases => '',
);

sub new {
    my ( $class, $args ) = @_;
    $args->{metadata} = $metadata;
    $args->{metadata}->{class} = $class;
    return $class->SUPER::new($args);
}

sub install   { return 1 }
sub upgrade   { return 1 }
sub uninstall { return 1 }

# --------------------------------------------------------------------------
# Configuração
# --------------------------------------------------------------------------

sub conf {
    my ($self) = @_;
    my %c;
    for my $k ( keys %DEFAULTS ) {
        my $v = $self->retrieve_data($k);
        $c{$k} = defined $v ? $v : $DEFAULTS{$k};
    }
    return \%c;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{cgi};
    my $op  = $cgi->param('op') // '';

    if ( $op eq 'cud-save' ) {
        my %data;
        for my $k ( keys %DEFAULTS ) {
            my $v = $cgi->param($k);
            # caixas de seleção desmarcadas não chegam no formulário
            $v = 0 if !defined $v && $k =~ /^(show_opac|opac_in_cite|show_intranet|allow_mode_toggle|uniform_title_brackets)$/;
            $data{$k} = $v // $DEFAULTS{$k};
        }
        $data{et_al_threshold} = $data{et_al_threshold} =~ /^\d+$/ ? $data{et_al_threshold} : 4;
        $self->store_data( \%data );
        $self->go_home();
        return;
    }

    my $template = $self->get_template( { file => 'configure.tt' } );
    $template->param( conf => $self->conf, version => $VERSION );
    $self->output_html( $template->output );
}

# Monta o formatador com a configuração salva
sub formatter {
    my ( $self, %over ) = @_;
    my $c = $self->conf;
    my %args = (
        mode                   => ( $over{mode} && $over{mode} =~ /^(essencial|completo)$/ ? $over{mode} : $c->{mode_default} ),
        et_al_threshold        => $c->{et_al_threshold},
        online_policy          => $c->{online_policy},
        uniform_title_brackets => $c->{uniform_title_brackets} ? 1 : 0,
        editor_default_abbrev  => $c->{editor_default_abbrev} || 'org.',
        parent_resolver        => $over{parent_resolver},
    );
    my $f = Koha::Plugin::BR::NBR6023::Formatter->new(%args);
    # frases locais de "não identificado", uma por linha
    for my $pair ( [ extra_place_phrases => 'unidentified_place' ], [ extra_publisher_phrases => 'unidentified_publisher' ] ) {
        my ( $key, $slot ) = @$pair;
        for my $line ( split /\r?\n/, $c->{$key} // '' ) {
            $line =~ s/^\s*\[?\s*|\s*\]?\s*$//g;
            next unless length $line;
            push @{ $f->{$slot} }, qr/^\[?\s*\Q$line\E\s*\]?$/i;
        }
    }
    return $f;
}

# --------------------------------------------------------------------------
# API REST: GET /api/v1/contrib/abnt/biblios/{biblio_id}/reference
# --------------------------------------------------------------------------

sub api_namespace { return 'abnt' }

sub api_routes {
    my ( $self, $args ) = @_;
    my $spec = $self->mbf_read('openapi.json');
    utf8::encode($spec) if utf8::is_utf8($spec);    # mbf_read devolve bytes; garante o mesmo aqui
    return decode_json($spec);
}

# --------------------------------------------------------------------------
# Botão no OPAC e na intranet
# --------------------------------------------------------------------------

sub opac_js {
    my ($self) = @_;
    my $c = $self->conf;
    return '' unless $c->{show_opac};
    return $self->_js( staff => 0 );
}

sub intranet_js {
    my ($self) = @_;
    my $c = $self->conf;
    return '' unless $c->{show_intranet};
    return $self->_js( staff => 1 );
}

sub _js {
    my ( $self, %o ) = @_;
    my $c   = $self->conf;
    # JSON em ASCII puro (\u escapes): seguro dentro do HTML, seja a saída bytes ou caracteres
    my $cfg = JSON->new->ascii(1)->canonical(1)->encode(
        {
            api         => '/api/v1/contrib/abnt/biblios/',
            label       => $c->{label} || $DEFAULTS{label},
            citeLabel   => $c->{cite_label} || $DEFAULTS{cite_label},
            opacInCite  => $c->{opac_in_cite} ? JSON::true : JSON::false,
            staff       => $o{staff} ? JSON::true : JSON::false,
            allowMode   => $c->{allow_mode_toggle} ? JSON::true : JSON::false,
            defaultMode => $c->{mode_default},
        }
    );
    my $js = $self->mbf_read('abnt.js');
    return qq{<script>window.ABNT_CFG = $cfg;</script>\n<script>\n$js\n</script>\n};
}

1;
