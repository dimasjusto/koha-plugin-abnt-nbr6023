package Koha::Plugin::BR::NBR6023::Formatter;

# Gera referências ABNT NBR 6023:2025 a partir de registros MARC21 (RDA ou AACR2).
# Perl puro sobre MARC::Record: não depende do Koha, para poder ser testado isoladamente.
# A saída é uma lista de segmentos { t => texto, b => negrito, i => itálico },
# renderizada depois em HTML ou texto puro.

use strict;
use warnings;
use utf8;
use Unicode::Normalize qw(NFD);
use MARC::Field;

our $VERSION = '0.1.1';

my @MESES = qw(jan. fev. mar. abr. maio jun. jul. ago. set. out. nov. dez.);

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        mode             => 'essencial',    # essencial | completo
        et_al_threshold  => 4,              # 0 = listar todos (8.1.1.1); 4 = primeiro + et al. (8.1.1.2)
        uniform_title_brackets => 1,        # 110/111 + 240 → BRASIL. [Constituição (1988)].
        online_policy    => 'recurso',      # recurso (856 _0, ou 008/23 = o) | sempre (aceita também 856 _1)
        access_date      => undef,          # [ano, mês, dia]; padrão = hoje
        parent_resolver  => undef,          # sub ($w) { return MARC::Record ou undef }
        editor_default_abbrev => 'org.',    # termo RDA "editor" sem pista no 245 $c
        unidentified_place => [
            qr/^\[?\s*(lugar|local)\s+de\s+publica\S*\s+n[aã]o\s+identificad[oa]\s*\]?$/i,
            qr/^\[?\s*s\.\s*l\.?\s*\]?$/i,
            qr/^\[?\s*sine\s+loco\s*\]?$/i,
            qr/^\[?\s*place\s+of\s+publication\s+not\s+identified\s*\]?$/i,
        ],
        unidentified_publisher => [
            qr/^\[?\s*(editora|editor|publicador)\s+n[aã]o\s+identificad[oa]\s*\]?$/i,
            qr/^\[?\s*s\.\s*n\.?\s*\]?$/i,
            qr/^\[?\s*sine\s+nomine\s*\]?$/i,
            qr/^\[?\s*publisher\s+not\s+identified\s*\]?$/i,
        ],
        %args,
    };
    $self->{author_roles} //= { map { $_ => 1 } qw(autor autora author aut cre criador) };
    $self->{editor_roles} //= {
        map { $_ => 1 } qw(editor organizador organizadora coordenador coordenadora
          compilador compiladora diretor diretora edt com pbd)
    };
    # responsabilidades secundárias (8.1.1.6), só no modo completo
    $self->{secondary_roles} //= {
        tradutor => 'Tradução de',     tradutora => 'Tradução de', trl => 'Tradução de',
        ilustrador => 'Ilustrações de', ilustradora => 'Ilustrações de', ill => 'Ilustrações de',
        prefaciador => 'Prefácio de',  prefaciadora => 'Prefácio de', wpr => 'Prefácio de', aui => 'Prefácio de',
        orientador => 'Orientador:',   orientadora => 'Orientador:', ths => 'Orientador:',
        editor => 'Organização de',    organizador => 'Organização de', organizadora => 'Organização de', edt => 'Organização de',
        coordenador => 'Coordenação de', coordenadora => 'Coordenação de',
    };
    return bless $self, $class;
}

# ---------------------------------------------------------------------------
# API pública
# ---------------------------------------------------------------------------

sub format {
    my ( $self, $rec ) = @_;
    my $ctx = { warnings => [] };
    my $type = $self->detect_type($rec, $ctx);
    my @el;
    if    ( $type eq 'periodico' ) { @el = $self->_serial( $rec, $ctx ) }
    elsif ( $type eq 'artigo' )    { @el = $self->_article( $rec, $ctx ) }
    elsif ( $type eq 'parte' )     { @el = $self->_part( $rec, $ctx ) }
    else                           { @el = $self->_monograph( $rec, $ctx, 'full' ) }
    return { type => $type, segments => _join_elements(@el), warnings => $ctx->{warnings} };
}

sub to_html {
    my ( $class, $segs ) = @_;
    my $out = '';
    for my $s (@$segs) {
        my $t = _esc( $s->{t} );
        $t = "<i>$t</i>"           if $s->{i};
        $t = "<strong>$t</strong>" if $s->{b};
        $out .= $t;
    }
    return $out;
}

sub to_text {
    my ( $class, $segs ) = @_;
    return join '', map { $_->{t} } @$segs;
}

# ---------------------------------------------------------------------------
# Tipo documental
# ---------------------------------------------------------------------------

sub detect_type {
    my ( $self, $rec, $ctx ) = @_;
    my $ldr  = $rec->leader // '';
    my $bl   = substr( $ldr, 7, 1 ) // 'm';
    my $f773 = $rec->field('773');
    return 'periodico' if $bl eq 's';
    if ( $f773 ) {
        return 'artigo' if $bl eq 'b';
        return 'parte'  if $bl eq 'a';
        # 773 em monografia: decide pelo registro-pai, quando acessível
        my $p = $self->_parent($f773, $ctx, 1);
        return 'artigo' if $p && substr( $p->leader, 7, 1 ) eq 's';
        return 'parte';
    }
    return 'monografia';
}

# ---------------------------------------------------------------------------
# Construtores por tipo
# ---------------------------------------------------------------------------

# Monografia no todo (7.1, 7.2) e legislação em monografia (7.11.1).
# $scope = 'full' (referência própria) ou 'host' (documento no todo após In:)
sub _monograph {
    my ( $self, $rec, $ctx, $scope ) = @_;
    my @el;
    my ( $entry, $by_title ) = $self->_entry($rec, $ctx);
    push @el, $entry if $entry;
    my $ut = $self->_uniform_title_element($rec);
    push @el, $ut if $ut;
    push @el, $self->_title_element( $rec, bold => !$by_title, upper_first => $by_title );
    if ( $scope eq 'full' && $self->_complete ) {
        push @el, $_ for $self->_secondary_resp($rec);
    }
    my $ed = $self->_edition($rec);
    push @el, [ _s($ed) ] if $ed;
    push @el, $self->_imprint($rec, $ctx);
    return @el if $scope eq 'host';

    my $carrier = $self->_carrier($rec);
    if ( $self->_complete ) {
        my $phys = $self->_physical($rec);
        push @el, [ _s($phys) ] if $phys;
        my $ser = $self->_series($rec);
        push @el, [ _s($ser) ] if $ser;
        push @el, $_ for $self->_notes_complete($rec);
    }
    elsif ($carrier) {
        push @el, [ _s($carrier) ];
    }
    push @el, $self->_doi($rec);
    push @el, $self->_online( $rec, $ctx );
    return @el;
}

# Parte de monografia (7.3, 7.4)
sub _part {
    my ( $self, $rec, $ctx ) = @_;
    my @el;
    my ( $entry, $by_title ) = $self->_entry($rec, $ctx);
    push @el, $entry if $entry;
    push @el, $self->_title_element( $rec, bold => 0, upper_first => $by_title );

    my $f773   = $rec->field('773');
    my $parent = $self->_parent($f773, $ctx);
    my @host;
    if ($parent) {
        @host = $self->_monograph( $parent, $ctx, 'host' );
    }
    else {
        push @{ $ctx->{warnings} }, 'Registro-pai não localizado: documento no todo montado só com o 773.';
        @host = $self->_host_from_773($f773);
    }
    # "In:" em itálico, unido ao primeiro elemento do documento no todo
    if (@host) {
        unshift @{ $host[0] }, _s( 'In', i => 1 ), _s(': ');
        push @el, @host;
    }
    my $loc = _pages_from_773($f773);
    push @el, [ _s($loc) ] if $loc;
    push @el, $self->_doi($rec);
    push @el, $self->_online( $rec, $ctx );
    return @el;
}

# Artigo de publicação periódica (7.7.5, 7.7.6) e legislação publicada em periódico
sub _article {
    my ( $self, $rec, $ctx ) = @_;
    my @el;
    my ( $entry, $by_title ) = $self->_entry($rec, $ctx);
    push @el, $entry if $entry;
    my $ut = $self->_uniform_title_element($rec);
    push @el, $ut if $ut;
    push @el, $self->_title_element( $rec, bold => 0, upper_first => $by_title );

    my $f773   = $rec->field('773');
    my $parent = $self->_parent($f773, $ctx);

    # título do periódico: 773 $t; na falta, 245 do pai
    my $jt = $f773->subfield('t');
    my ( $jmain, $jsub );
    if ( defined $jt && $jt =~ /\S/ ) {
        ( $jmain, $jsub ) = split /\s*:\s+/, _clean_title($jt), 2;
    }
    elsif ($parent) {
        ( $jmain, $jsub ) = $self->_title_strings($parent);
    }
    $jmain //= '[periódico não identificado]';

    my @j = ( _s( $jmain, b => 1 ) );
    push @j, _s(": $jsub") if $jsub;

    # local: 773 $d → 264 $a do pai → omitido
    my $place;
    if ( my $d = $f773->subfield('d') ) {
        ($place) = split /\s*:\s*/, $d;
        $place = _trim_punct($place);
        undef $place if $place && $place =~ /^\d/;
    }
    if ( !$place && $parent ) {
        my $pf = $self->_imprint_field($parent);
        my $imp = $pf ? $self->_imprint_data($pf) : {};
        $place = $imp->{place} if $imp->{place} && !$imp->{place_unknown};
    }
    if ($place) { push @j, _s(", $place") }
    else {
        push @{ $ctx->{warnings} }, 'Local do periódico não encontrado (773 $d e registro-pai): omitido.';
    }
    my $g = _normalize_773g( scalar $f773->subfield('g') );
    push @j, _s(", $g") if $g;
    push @el, \@j;
    push @el, $self->_doi($rec);
    push @el, $self->_online( $rec, $ctx );
    return @el;
}

# Coleção de publicação periódica (7.7.1, 7.7.2)
sub _serial {
    my ( $self, $rec, $ctx ) = @_;
    my @el;
    my ( $main, $sub ) = $self->_title_strings($rec);
    my @t = ( _s( _uc($main) ) );
    push @t, _s(": $sub") if $sub;
    push @el, \@t;

    my @f264 = grep { $_->indicator(2) eq '1' } $rec->field('264');
    @f264 = $rec->field('260') unless @f264;
    my ($first) = grep { $_->indicator(1) =~ /^[ #]?$/ } @f264;
    $first //= $f264[0];
    my $imp = $first ? $self->_imprint_data($first) : {};

    # datas: início do primeiro 264, fim do último (vazio = em curso)
    my @c = map { scalar $_->subfield('c') } grep { $_->subfield('c') } @f264;
    my ( $start, $end ) = ( '', '' );
    if (@c) {
        ( my $first_c = $c[0] ) =~ s/^\s+|[\s.,;]+$//g;
        if    ( $first_c =~ /^(.*)-$/ )                { $start = $1 }    # 2009- / [199-?]-
        elsif ( $first_c =~ /^(\S+?\d\S*?)-(\d{4}.*)$/ ) { $start = $1 }    # 2001-2010
        else                                           { $start = $first_c }
        ( my $last = $c[-1] ) =~ s/^\s+|[\s.,;]+$//g;
        if    ( $last =~ /-$/ )            { $end = '' }
        elsif ( $last =~ /-(\d{4}\S*)$/ )  { $end = $1 }
        else                               { $end = $last eq $start ? "=$start" : $last }
    }
    if ( !$start ) {
        my $f008 = $rec->field('008');
        if ($f008) {
            my $d = $f008->data;
            $start = substr( $d, 7, 4 );
            my $e = substr( $d, 11, 4 );
            $end = $e =~ /^\d{4}$/ && $e ne '9999' ? $e : '';
        }
    }
    my $dates = $end =~ /^=(.*)/ ? $1 : $end ? "$start-$end" : "$start- .";
    push @el, $self->_imprint_segments( $imp, $dates );

    my $carrier = $self->_carrier($rec);
    push @el, [ _s($carrier) ] if $carrier;
    if ( $self->_complete ) {
        if ( my $issn = $rec->subfield( '022', 'a' ) ) { push @el, [ _s("ISSN $issn") ] }
        if ( my $per = $rec->subfield( '310', 'a' ) ) { push @el, [ _s( _trim_punct($per) ) ] }
    }
    push @el, $self->_doi($rec);
    push @el, $self->_online( $rec, $ctx );
    return @el;
}

# ---------------------------------------------------------------------------
# Autoria (8.1)
# ---------------------------------------------------------------------------

# Retorna ( [segmentos], entrada_pelo_titulo )
sub _entry {
    my ( $self, $rec, $ctx ) = @_;
    my $c = $rec->subfield( '245', 'c' ) // '';
    my $more = $c =~ /\[\s*(e outros|et al\.?|and others|y otros)\s*\]/i;

    if ( my $f = $rec->field('100') ) {
        my @names = ( $self->_person($f) );
        push @names, map { $self->_person($_) }
          grep { $self->_has_role( $_, 'author' ) } $rec->field('700');
        return ( $self->_name_list( \@names, $more ), 0 );
    }
    if ( my $f = $rec->field('110') ) {
        my @names = ( $self->_corporate($f) );
        return ( $self->_name_list( \@names, 0 ), 0 );
    }
    if ( my $f = $rec->field('111') ) {
        return ( [ _s( $self->_event($f) ) ], 0 );
    }

    my @authors = grep { $self->_has_role( $_, 'author' ) } $rec->field('700');
    my @editors = grep { $self->_has_role( $_, 'editor' ) } $rec->field('700');
    my $c_editorial = _fold($c) =~ /\b(coordena\w*|organiza\w*|orgs?\.?|compila\w*|diret\w*|editor\w*|eds?\.)/;

    if ( @editors && ( $c_editorial || !@authors ) ) {
        my @names = map { $self->_person($_) } _order_by_c( $c, @editors );
        my $abbr  = $self->_editor_abbrev( $c, $editors[0] );
        my $segs  = $self->_name_list( \@names, $more );
        push @$segs, _s(" ($abbr)");
        return ( $segs, 0 );
    }
    if (@authors) {
        my @names = map { $self->_person($_) } _order_by_c( $c, @authors );
        return ( $self->_name_list( \@names, $more ), 0 );
    }
    return ( undef, 1 );    # entrada pelo título (8.1.4)
}

sub _name_list {
    my ( $self, $names, $more ) = @_;
    my %seen;
    my @n = grep { !$seen{ _fold($_) }++ } @$names;
    my $th = $self->{et_al_threshold};
    if ( @n && ( $more || ( $th && @n >= $th ) ) ) {
        return [ _s( $n[0] . ' ' ), _s( 'et al.', i => 1 ) ];
    }
    return [ _s( join '; ', @n ) ];
}

sub _person {
    my ( $self, $f ) = @_;
    my $a = $f->subfield('a') // '';
    $a =~ s/\s+/ /g;
    $a =~ s/,\s*\d{3,4}\s*-\s*(\d{3,4})?\s*$//;    # datas digitadas dentro do $a
    $a =~ s/[\s,;:]+$//;
    $a =~ s/(?<![\s.][A-Z])\.$// unless $a =~ /\b[A-Z]\.$/;    # mantém ponto de iniciais
    my ( $sur, $fore ) = split /,\s*/, $a, 2;
    return _uc($sur) unless defined $fore && length $fore;
    return _uc($sur) . ", $fore";
}

sub _person_direct {
    my ( $self, $f ) = @_;
    my $a = $f->subfield('a') // '';
    $a =~ s/\s+/ /g;
    $a =~ s/[\s,;:.]+$//;
    my ( $sur, $fore ) = split /,\s*/, $a, 2;
    return defined $fore ? "$fore $sur" : $sur;
}

sub _corporate {
    my ( $self, $f ) = @_;
    my $a = _trim_punct( $f->subfield('a') // '' );
    my $name = $f->indicator(1) eq '1' ? _uc_outside_parens($a) : _uc_outside_parens($a);
    my @b = map { _trim_punct($_) } $f->subfield('b');
    return join '. ', $name, @b;
}

sub _event {
    my ( $self, $f ) = @_;
    my $name = _trim_punct( $f->subfield('a') // '' );
    $name =~ s/\s+/ /g;
    my @parts = ( _uc($name) );
    for my $code (qw(n d c)) {
        for my $v ( $f->subfield($code) ) {
            $v =~ s/[()]//g;
            $v = _trim_punct($v);
            next unless length $v;
            $v .= '.' if $code eq 'n' && $v =~ /^\d+$/;
            push @parts, $v;
        }
    }
    return join ', ', @parts;
}

sub _has_role {
    my ( $self, $f, $kind ) = @_;
    my $set = $kind eq 'author' ? $self->{author_roles} : $self->{editor_roles};
    my @roles = ( map( { _fold_role($_) } $f->subfield('e') ), map( { lc } $f->subfield('4') ) );
    return scalar grep { $set->{$_} } @roles;
}

sub _roles {
    my ( $f ) = @_;
    return ( map( { _fold_role($_) } $f->subfield('e') ), map( { lc } $f->subfield('4') ) );
}

sub _editor_abbrev {
    my ( $self, $c, $f ) = @_;
    my $fc = _fold($c);
    return 'coord.' if $fc =~ /coordena/;
    return 'org.'   if $fc =~ /organiza|\borgs?\b/;
    return 'comp.'  if $fc =~ /compila/;
    return 'dir.'   if $fc =~ /diret/;
    return 'ed.'    if $fc =~ /\beditor|\beds?\b/;
    my %by = ( coordenador => 'coord.', coordenadora => 'coord.', compilador => 'comp.',
               compiladora => 'comp.', com => 'comp.', diretor => 'dir.', diretora => 'dir.',
               organizador => 'org.', organizadora => 'org.' );
    for my $r ( _roles($f) ) { return $by{$r} if $by{$r} }
    return $self->{editor_default_abbrev};
}

# Ordena os nomes pela posição do sobrenome na indicação de responsabilidade (245 $c),
# para que o primeiro nome da referência seja o que vem primeiro no documento.
sub _order_by_c {
    my ( $c, @fields ) = @_;
    my $fc = _fold($c);
    my $i  = 0;
    my @k  = map {
        my $sur = ( split /,/, ( $_->subfield('a') // '' ) )[0];
        my $pos = index( $fc, _fold( $sur // '' ) );
        [ $_, $pos < 0 ? 1e9 : $pos, $i++ ]
    } @fields;
    return map { $_->[0] } sort { $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @k;
}

sub _secondary_resp {
    my ( $self, $rec ) = @_;
    my $has_main = $rec->field('100') || $rec->field('110') || $rec->field('111');
    my $c = $rec->subfield( '245', 'c' ) // '';
    my $editors_are_entry = !$has_main;
    my ( %by_label, @order );
    for my $f ( $rec->field('700') ) {
        next if $self->_has_role( $f, 'author' ) && !$has_main;
        next if $self->_has_role( $f, 'author' ) && $has_main && !$self->_has_role( $f, 'editor' );
        for my $r ( _roles($f) ) {
            my $label = $self->{secondary_roles}{$r} or next;
            next if $editors_are_entry && $self->_has_role( $f, 'editor' ) && $label =~ /^(Organização|Coordenação)/;
            push @order, $label unless $by_label{$label};
            push @{ $by_label{$label} }, $self->_person_direct($f);
            last;
        }
    }
    return map {
        my %s; my @n = grep { !$s{$_}++ } @{ $by_label{$_} };
        my $names = @n > 3 ? "$n[0] et al." : join( ', ', @n[ 0 .. $#n - 1 ] ) . ( @n > 1 ? ' e ' : '' ) . $n[-1];
        [ _s("$_ $names") ]
    } @order;
}

# ---------------------------------------------------------------------------
# Título (8.2)
# ---------------------------------------------------------------------------

sub _title_strings {
    my ( $self, $rec ) = @_;
    my $f = $rec->field('245') or return ( '[sem título]', undef );
    my ( @main, @sub );
    my $parallel = 0;
    for my $sf ( $f->subfields ) {
        my ( $code, $val ) = @$sf;
        if ( $code eq 'a' ) { push @main, $val; $parallel = 1 if $val =~ /=\s*$/ }
        elsif ( $code =~ /^[np]$/ ) { push @main, $val }
        elsif ( $code eq 'b' && !$parallel ) { push @sub, $val }
    }
    my $main = join ' ', map { _clean_title($_) } @main;
    $main =~ s/\.?\s+(?=\S)/ /g if 0;
    my $sub = @sub ? join( ' ', map { _clean_title($_) } @sub ) : undef;
    return ( $main, $sub );
}

sub _title_element {
    my ( $self, $rec, %o ) = @_;
    my ( $main, $sub ) = $self->_title_strings($rec);
    if ( $o{upper_first} ) {
        my $ind2 = $rec->field('245') ? $rec->field('245')->indicator(2) : '0';
        $main = _uc_first_words( $main, ( $ind2 =~ /^[1-9]$/ ) ? 2 : 1 );
    }
    my @seg = ( _s( $main, b => $o{bold} ) );
    push @seg, _s(": $sub") if defined $sub && length $sub;
    return \@seg;
}

sub _uniform_title_element {
    my ( $self, $rec ) = @_;
    return unless $self->{uniform_title_brackets};
    return unless $rec->field('110') || $rec->field('111');
    my $f = $rec->field('240') or return;
    my $t = join ' ', map { _trim_punct($_) } $f->subfield('a'), $f->subfield('d'), $f->subfield('f'),
      $f->subfield('k'), $f->subfield('n'), $f->subfield('p');
    return [ _s("[$t]") ];
}

# ---------------------------------------------------------------------------
# Edição (8.3)
# ---------------------------------------------------------------------------

my %ORD = (
    primeira => 1, segunda => 2, terceira => 3, quarta => 4, quinta => 5, sexta => 6,
    'sétima' => 7, setima => 7, oitava => 8, nona => 9, 'décima' => 10, decima => 10,
);
my @ED_WORDS = (
    [ qr/edi[cç][aã]o/i,               'ed.' ],
    [ qr/revista|revisada/i,           'rev.' ],
    [ qr/atualizada|atualizado/i,      'atual.' ],
    [ qr/aumentada/i,                  'aum.' ],
    [ qr/ampliada/i,                   'ampl.' ],
    [ qr/reimpress[aã]o/i,             'reimpr.' ],
    [ qr/corrigida/i,                  'corr.' ],
);

sub _edition {
    my ( $self, $rec ) = @_;
    my $e = $rec->subfield( '250', 'a' ) or return;
    $e = _trim_isbd($e);
    # só normaliza enunciados em português; os demais seguem como no documento (8.3)
    return $e unless $e =~ /edi[cç][aã]o|\bed\.|reimpr|tiragem|revista|atualiz/i;
    $e =~ s/\b(\d+)\s*(?:ª|a|º|o)?\.?(?=\s+(?:edi|ed\.|reimpr|tiragem))/$1./g;
    for my $w ( keys %ORD ) { $e =~ s/\b\Q$w\E\b/$ORD{$w}./gi }
    for my $p (@ED_WORDS) { my ( $re, $ab ) = @$p; $e =~ s/\b$re\b\.?/$ab/g }
    $e =~ s/\bed\.,\s+(?=(rev|atual|aum|ampl|corr)\.)/ed. /g;
    $e =~ s/\s+/ /g;
    $e =~ s/\.\.$/./;
    return $e;
}

# ---------------------------------------------------------------------------
# Imprenta (8.4–8.6)
# ---------------------------------------------------------------------------

sub _imprint {
    my ( $self, $rec, $ctx ) = @_;
    my $f = $self->_imprint_field($rec);
    my $imp = $f ? $self->_imprint_data($f) : { place_unknown => 1, pub_unknown => 1, pairs => [] };
    my $date = $f ? _trim_isbd( $f->subfield('c') // '' ) : '';
    $date =~ s/^©\s*/c/;
    if ( !$date ) {
        my ($cp) = grep { $_->indicator(2) eq '4' } $rec->field('264');
        if ( $cp && ( my $c = $cp->subfield('c') ) ) {
            $c =~ s/^(?:©|c|copyright)\s*//i;
            $date = 'c' . _trim_punct($c);
        }
    }
    if ( !$date && ( my $f008 = $rec->field('008') ) ) {
        my $d = substr( $f008->data, 7, 4 );
        if ( $d =~ /^\d{4}$/ ) { $date = "[$d]" }
        elsif ( $d =~ /^(\d{2,3})[u|]+$/ ) { $date = '[' . $1 . ( '-' x ( 4 - length $1 ) ) . ']' }
    }
    return $self->_imprint_segments( $imp, $date );
}

sub _imprint_field {
    my ( $self, $rec ) = @_;
    my @f = grep { $_->indicator(2) eq '1' } $rec->field('264');
    my ($cur) = grep { $_->indicator(1) eq '3' } @f;
    my ($first) = grep { $_->indicator(1) =~ /^[ #]?$/ } @f;
    return $first // $cur // $f[0] // $rec->field('260');
}

sub _imprint_data {
    my ( $self, $f ) = @_;
    my ( @places, @pubs );
    for my $sf ( $f->subfields ) {
        my ( $code, $v ) = @$sf;
        if    ( $code eq 'a' ) { push @places, _trim_isbd($v) }
        elsif ( $code eq 'b' ) { push @pubs, [ $#places, _clean_publisher( _trim_isbd($v) ) ] }
    }
    my @pairs;
    for my $p (@pubs) {
        my $pl = $places[ $p->[0] < 0 ? 0 : $p->[0] ] // '';
        push @pairs, [ $pl, $p->[1] ];
    }
    @pairs = map { [ $_, '' ] } @places if !@pairs && @places;
    my $is = sub { my ( $v, $list ) = @_; return 1 unless length( $v // '' ); return scalar grep { $v =~ $_ } @$list };
    my $place = $pairs[0] ? $pairs[0][0] : '';
    return {
        pairs         => \@pairs,
        place         => $place,
        place_unknown => $is->( $place, $self->{unidentified_place} ),
        pub_unknown   => !@pairs || $is->( $pairs[0][1], $self->{unidentified_publisher} ),
        unknown_place_re => $self->{unidentified_place},
        unknown_pub_re   => $self->{unidentified_publisher},
    };
}

sub _imprint_segments {
    my ( $self, $imp, $date ) = @_;
    my @pairs = @{ $imp->{pairs} || [] };
    my $isu = sub { my ( $v, $l ) = @_; return 1 unless length( $v // '' ); scalar grep { $v =~ $_ } @$l };
    my @seg;
    if ( !@pairs || ( $imp->{place_unknown} && $imp->{pub_unknown} ) ) {
        @seg = ( _s('['), _s( 'S. l.', i => 1 ), _s(': '), _s( 's. n.', i => 1 ), _s(']') );
    }
    else {
        @pairs = ( $pairs[0] ) if @pairs >= 3;    # três ou mais editoras: a primeira (8.5)
        my %pl; $pl{ $_->[0] }++ for @pairs;
        my $same = keys(%pl) == 1;
        my $first = 1;
        for my $i ( 0 .. $#pairs ) {
            my ( $p, $e ) = @{ $pairs[$i] };
            my $pu = $isu->( $p, $imp->{unknown_place_re} || $self->{unidentified_place} );
            my $eu = $isu->( $e, $imp->{unknown_pub_re}   || $self->{unidentified_publisher} );
            if ( $i == 0 || !$same ) {
                push @seg, _s('; ') if $i > 0;
                if ($pu) { push @seg, _s('['), _s( ( $i == 0 ? 'S. l.' : 's. l.' ), i => 1 ), _s(']') }
                else     { push @seg, _s($p) }
            }
            push @seg, _s(': ');
            if ($eu) { push @seg, _s('['), _s( 's. n.', i => 1 ), _s(']') }
            else     { push @seg, _s($e) }
        }
    }
    push @seg, _s(", $date") if length( $date // '' );
    return \@seg;
}

sub _clean_publisher {
    my ($p) = @_;
    $p =~ s/,?\s*\b(Ltda|LTDA|S\.\s?A|S\/A|Eireli|EIRELI|ME|EPP)\b\.?\s*$//;
    $p =~ s/[\s,]+$//;
    return $p;
}

# ---------------------------------------------------------------------------
# Descrição física, série, notas (8.7–8.11)
# ---------------------------------------------------------------------------

sub _physical {
    my ( $self, $rec ) = @_;
    my $f = $rec->field('300') or return;
    my @parts;
    my $a = _trim_isbd( $f->subfield('a') // '' );
    if ( length $a ) {
        my $book = substr( $rec->leader, 6, 1 ) =~ /[at]/;
        $a =~ s/^1 recurso online\s*/$book ? 'E-book ' : ''/e;
        $a =~ s/^\s+|\s+$//g;
        $a = _abbr_phys($a);
        $a =~ s/^E-book\s*$/E-book/;
        $a =~ s/\(([^)]*?)\s*:\s*([^)]*)\)/($1, $2)/;
        $a = "1 $a" if $a =~ /^CD-ROM$/;
        $a = 'v.' if $a =~ /^volumes?$/i;
        push @parts, $a;
    }
    for my $code (qw(b c)) {
        my $v = _trim_isbd( $f->subfield($code) // '' );
        push @parts, _abbr_phys($v) if length $v;
    }
    my $s = join ', ', @parts;
    if ( my $e = $f->subfield('e') ) { $e = _trim_isbd($e); $e =~ s/\s*\(.*\)//; $s .= " + $e" }
    return $s;
}

sub _abbr_phys {
    my ($s) = @_;
    $s =~ s/\bp[áa]ginas?\b/p./g;
    $s =~ s/\bfolhas?\b/f./g;
    $s =~ s/\b(\d+)\s+volumes?\b/$1 v./g;
    $s =~ s/\bilustra[çc](?:ões|ão)\b/il./g;
    $s =~ s/\b(?:em cores|coloridas?|coloridos?)\b/color./g;
    $s =~ s/,\s*color\./ color./g;
    $s =~ s/\s+:\s+/, /g;
    return $s;
}

sub _carrier {
    my ( $self, $rec ) = @_;
    my $c338 = _fold( $rec->subfield( '338', 'b' ) // $rec->subfield( '338', 'a' ) // '' );
    my $a300 = $rec->subfield( '300', 'a' ) // '';
    if ( $c338 =~ /^(cd|computer disc|disco)/ || $a300 =~ /CD-ROM|DVD/i ) {
        return $a300 =~ /DVD/i ? '1 DVD' : ( $a300 =~ /(\d+)\s*CD-ROM/i ? "$1 CD-ROM" : 'CD-ROM' );
    }
    return;
}

sub _series {
    my ( $self, $rec ) = @_;
    my @s;
    for my $f ( $rec->field('490') ) {
        my $a = _trim_isbd( $f->subfield('a') // '' );
        next unless length $a;
        my $v = $f->subfield('v');
        if ($v) {
            $v = _trim_isbd($v);
            $v =~ s/\bvolume\s*/v. /gi;
            $v =~ s/\bn[úu]mero\s*/n. /gi;
            $a .= ", $v";
        }
        push @s, "($a)";
    }
    return join ' ', @s;
}

sub _notes_complete {
    my ( $self, $rec ) = @_;
    my @n;
    if ( $rec->field('100') && ( my $u = $rec->field('240') ) ) {
        push @n, [ _s( 'Título original: ' . _trim_punct( $u->subfield('a') // '' ) ) ];
    }
    for my $f ( $rec->field('020') ) {
        my $isbn = $f->subfield('a') or next;
        $isbn =~ s/\s.*$//;
        push @n, [ _s("ISBN $isbn") ];
        last;
    }
    return @n;
}

sub _doi {
    my ( $self, $rec ) = @_;
    for my $f ( $rec->field('024') ) {
        next unless lc( $f->subfield('2') // '' ) eq 'doi';
        my $d = $f->subfield('a') or next;
        return [ _s("DOI: $d") ];
    }
    return;
}

# Disponível em / Acesso em (6.6): só quando o documento referenciado é o recurso online.
#   856 _0 (o próprio recurso)                → entra
#   856 _ (branco) ou _8 + 008/23 = o, q, s   → entra
#   856 _1 (versão: impresso digitalizado), _2 (relacionado) → não entra
# online_policy => 'sempre' aceita também o 856 _1 (comportamento antigo).
sub _online {
    my ( $self, $rec, $ctx ) = @_;
    my @all = grep { $_->subfield('u') } $rec->field('856');
    my $form = $self->_form_of_item($rec);
    my @f = grep { $_->indicator(2) eq '0' } @all;
    @f = grep { $_->indicator(2) =~ /^[ #8]$/ } @all if !@f && $form =~ /^[oqs]$/;
    @f = grep { $_->indicator(2) eq '1' } @all if !@f && $self->{online_policy} eq 'sempre';
    if ( !@f ) {
        push @{ $ctx->{warnings} }, 'URL omitida: o 856 aponta para uma versão digital (2º ind. 1), não para o recurso descrito.'
          if grep { $_->indicator(2) eq '1' } @all;
        return;
    }
    my $u = $f[0]->subfield('u');
    my ( $y, $m, $d ) = @{ $self->{access_date} || _today() };
    return [ _s("Disponível em: $u. Acesso em: $d $MESES[$m-1] $y") ];
}

# 008/23 (forma do item) para livros e recursos contínuos; 008/29 para mapas e visuais
sub _form_of_item {
    my ( $self, $rec ) = @_;
    my $f = $rec->field('008') or return '';
    my $d = $f->data;
    my $t = substr( $rec->leader, 6, 1 );
    my $pos = $t =~ /[ekgor]/ ? 29 : 23;
    return length $d > $pos ? substr( $d, $pos, 1 ) : '';
}

sub _is_electronic {
    my ( $self, $rec ) = @_;
    my $m = _fold( $rec->subfield( '337', 'a' ) // '' ) . ' ' . _fold( $rec->subfield( '337', 'b' ) // '' );
    my $c = _fold( $rec->subfield( '338', 'a' ) // '' ) . ' ' . _fold( $rec->subfield( '338', 'b' ) // '' );
    return 1 if $m =~ /computer|computador|\bc\b/;
    return 1 if $c =~ /online|\bcr\b/;
    return 1 if ( $rec->subfield( '300', 'a' ) // '' ) =~ /recurso online/i;
    return 0;
}

# ---------------------------------------------------------------------------
# 773: registro-pai, documento no todo, numeração
# ---------------------------------------------------------------------------

sub _parent {
    my ( $self, $f773, $ctx, $quiet ) = @_;
    return unless $f773 && $self->{parent_resolver};
    my $key = $ctx->{_parent_key} //= 0;
    for my $w ( $f773->subfield('w') ) {
        my $id = $w; $id =~ s/^\([^)]*\)//; $id =~ s/^\s+|\s+$//g; $id =~ s/\.$//;
        my $p = $self->{parent_resolver}->($id);
        return $p if $p;
    }
    return;
}

sub _host_from_773 {
    my ( $self, $f ) = @_;
    my @el;
    my $t = $f->subfield('t');
    if ( my $a = $f->subfield('a') ) {
        my $fake = MARC::Field->new( '100', '1', ' ', a => $a );
        push @el, [ _s( $self->_person($fake) ) ];
    }
    if ($t) {
        my ( $m, $s ) = split /\s*:\s+/, _clean_title($t), 2;
        push @el, [ _s( $m, b => 1 ), ( $s ? _s(": $s") : () ) ];
    }
    if ( my $d = $f->subfield('d') ) {
        $d =~ s/,\s*(p\.|v\.|cap\.).*$//;
        $d =~ s/\s+:\s+/: /;
        $d = _trim_punct($d);
        push @el, [ _s($d) ] if length $d;
    }
    return @el;
}

sub _pages_from_773 {
    my ($f) = @_;
    for my $v ( $f->subfield('g'), $f->subfield('d') ) {
        next unless defined $v;
        if ( $v =~ /((?:v\.\s*\S+,\s*)?(?:cap\.\s*\S+,\s*)?p\.\s*[\dIVXLCivxlc\-–, ]+\d)/ ) {
            my $p = $1; $p =~ s/[,\s]+$//; return "$p.";
        }
        if ( $v =~ /p[áa]ginas?\s+([\d\-–]+)/i ) { return "p. $1." }
    }
    return;
}

sub _normalize_773g {
    my ($g) = @_;
    return '' unless defined $g && length $g;
    my $date = '';
    if ( $g =~ s/\s*\(([^)]*)\)// ) { $date = $1 }
    my @tok;
    for my $t ( split /,\s*/, $g ) {
        $t = _trim_punct($t);
        next unless length $t;
        $t =~ s/^(?:vol\.?|volume|v\.)\s*/v. /i;
        $t =~ s/^(?:n\.?|n[úu]mero|no\.)\s*/n. /i;
        $t =~ s/^(?:p\.?|p[áa]ginas?)\s*(?=\d|[IVXLC])/p. /i;
        $t =~ s/^ano\s*/ano /i;
        $t =~ s/^t\.\s*/t. /i;
        next if $t =~ /^(v|n|p|t)\.\s*$/;    # rótulo sem número (ex.: "n.")
        if ( $t =~ /^\d+(?:-\d+)?$/ && @tok && $tok[-1] =~ /^p\./ ) { $tok[-1] .= ", $t"; next }
        push @tok, $t;
    }
    $date = _trim_punct($date);
    push @tok, $date if length $date;
    return join ', ', @tok;
}

# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------

sub _complete { return $_[0]{mode} eq 'completo' }

sub _s { my ( $t, %o ) = @_; return { t => $t, b => $o{b} ? 1 : 0, i => $o{i} ? 1 : 0 } }

# Une os elementos com ". ", sem duplicar pontuação final (8 – pontuação)
sub _join_elements {
    my @el = grep { $_ && @$_ } @_;
    my @out;
    for my $i ( 0 .. $#el ) {
        if (@out) {
            my $prev = join '', map { $_->{t} } @out;
            if ( $prev =~ /[.?!]$/ ) { push @out, _s(' ') }
            else                     { push @out, _s('. ') }
        }
        push @out, @{ $el[$i] };
    }
    my $txt = join '', map { $_->{t} } @out;
    push @out, _s('.') unless $txt =~ /[.?!]$/ || $txt =~ /- \.$/;
    # funde segmentos vizinhos de mesmo estilo
    my @m;
    for my $s (@out) {
        if ( @m && $m[-1]{b} == $s->{b} && $m[-1]{i} == $s->{i} ) { $m[-1]{t} .= $s->{t} }
        else { push @m, {%$s} }
    }
    return \@m;
}

sub _clean_title {
    my ($t) = @_;
    $t = _trim_isbd($t);
    $t =~ s/\s+\.\.\.$/ [...]/;
    $t =~ s/\s+([:;])(?=\s|"|$)/$1/g;
    $t =~ s/\s+:"/:"/g;
    $t =~ s/\s{2,}/ /g;
    return $t;
}

# Remove a pontuação ISBD final de um subcampo
sub _trim_isbd {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/\s*[\/:;=,]\s*$//;
    $v =~ s/(?<!\.\.)(?<!\b[A-Za-z])\.$// unless $v =~ /\b(?:ed|rev|atual|aum|ampl|reimpr|corr|v|n|p|f|il|color|etc|Jr|org|coord|comp|dir)\.$/i;
    $v =~ s/\s+$//;
    return $v;
}

sub _trim_punct {
    my ($v) = @_;
    return '' unless defined $v;
    $v =~ s/^\s+|\s+$//g;
    $v =~ s/[\s.,;:\/]+$// unless $v =~ /\b[A-Z]\.$/ || $v =~ /\b(?:etc|v|n|p|Jr)\.$/;
    $v =~ s/\s+$//;
    return $v;
}

sub _uc { my ($s) = @_; return uc( $s // '' ) }

sub _uc_outside_parens {
    my ($s) = @_;
    return join '', map { /^\(/ ? $_ : uc $_ } split /(\([^)]*\))/, $s;
}

sub _uc_first_words {
    my ( $s, $n ) = @_;
    my @w = split / /, $s, -1;
    $n = @w if $n > @w;
    $w[$_] = uc $w[$_] for 0 .. $n - 1;
    return join ' ', @w;
}

sub _fold {
    my ($s) = @_;
    $s = NFD( lc( $s // '' ) );
    $s =~ s/\p{Mn}//g;
    return $s;
}

sub _fold_role {
    my $r = _fold( $_[0] );
    $r =~ s/[^a-z ]//g;
    $r =~ s/^\s+|\s+$//g;
    return $r;
}

sub _esc {
    my ($t) = @_;
    $t =~ s/&/&amp;/g; $t =~ s/</&lt;/g; $t =~ s/>/&gt;/g; $t =~ s/"/&quot;/g;
    return $t;
}

sub _today {
    my @t = localtime;
    return [ $t[5] + 1900, $t[4] + 1, $t[3] ];
}

1;
