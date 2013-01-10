#!/usr/bin/perl -wl

use strict;
use JSON;
use List::Util qw(sum);
use File::Basename qw(dirname);

BEGIN { push @INC, dirname $0; }

use factions;
use map;
use tiles;

my @cults = qw(EARTH FIRE WATER AIR);
my @ledger = ();
my @error = ();
my @score_tiles = ();
my $round = 0;
my @bridges = ();

my %pool = (
    # Resources
    C => 1000,
    W => 1000,
    P => 1000,
    VP => 1000,

    # Power
    P1 => 10000,
    P2 => 10000,
    P3 => 10000,

    # Cult tracks
    EARTH => 100,
    FIRE => 100,
    WATER => 100,
    AIR => 100,

    # Temporary pseudo-resources for tracking activation effects
    SHOVEL => 10000,
    FREE_TF => 10000,
    FREE_TP => 10000,
    CULT => 10000,
    GAIN_FAVOR => 10000,
    GAIN_SHIP => 10000,
    CONVERT_W_TO_P => 3,
);

$pool{"ACT$_"}++ for 1..6;
$pool{"BON$_"}++ for 1..9;
$map{"BON$_"}{C} = 0 for 1..9;
$pool{"FAV$_"}++ for 1..4;
$pool{"FAV$_"} += 3 for 5..12;
$pool{"TW$_"} += 2 for 1..5;

for my $cult (@cults) {
    $map{"${cult}1"} = { gain => { $cult => 3 } };
    $map{"${cult}$_"} = { gain => { $cult => 2 } } for 2..4;
}

## 

sub command;

sub current_score_tile {
    if ($round > 0) {
        return $tiles{$score_tiles[$round - 1]};
    }
}

sub pay {
    my ($faction_name, $cost) = @_;

    for my $currency (keys %{$cost}) {
        my $amount = $cost->{$currency};
        command $faction_name, "-${amount}$currency";            
    }
}

sub gain {
    my ($faction_name, $cost) = @_;

    for my $currency (keys %{$cost}) {
        my $amount = $cost->{$currency};
        command $faction_name, "+${amount}$currency";            
    }
}

sub maybe_score_current_score_tile {
    my ($faction_name, $type) = @_;

    my $scoring = current_score_tile;
    if ($scoring) {
        my $gain = $scoring->{vp}{$type};
        if ($gain) {
            command $faction_name, "+${gain}vp"
        }
    }
}

sub maybe_score_favor_tile {
    my ($faction_name, $type) = @_;

    for my $tile (keys %{$factions{$faction_name}}) {
        next if !$factions{$faction_name}{$tile};
        if ($tile =~ /^FAV/) {
            my $scoring = $tiles{$tile}{vp};
            if ($scoring) {
                my $gain = $scoring->{$type};
                if ($gain) {
                    command $faction_name, "+${gain}vp"
                }
            }
        }
    }
}

sub maybe_gain_faction_special {
    my ($faction_name, $type) = @_;
    my $faction = $factions{$faction_name};

    my $enable_if = $faction->{special}{enable_if};
    if ($enable_if) {
        for my $building (keys %{$enable_if}) {
            return if $faction->{buildings}{$building}{level} != $enable_if->{$building};
        }
    }

    gain $faction_name, $faction->{special}{$type};
}

sub faction_income {
    my $faction_name = shift;
    my $faction = $factions{$faction_name};

    my %total_income = map { $_, 0 } qw(C W P PW);

    my %buildings = %{$faction->{buildings}};
    for my $building (values %buildings) {
        if (exists $building->{income}) {
            my %building_income = %{$building->{income}};
            for my $type (keys %building_income) {
                my $delta = $building_income{$type}[$building->{level}];
                if ($delta) {
                    $total_income{$type} += $delta;
                }
            }
        }
    }

    for my $tile (keys %{$faction}) {
        if (!$faction->{$tile}) {
            next;
        }

        if ($tile =~ /^BON|FAV/) {
            my $tile_income = $tiles{$tile}{income};
            for my $type (keys %{$tile_income}) {
                $total_income{$type} += $tile_income->{$type};
            }
        }
    }

    my $scoring = current_score_tile;
    if ($scoring) {
        my %scoring_income = %{$scoring->{income}};

        my $mul = int($faction->{$scoring->{cult}} / $scoring->{req});
        for my $type (keys %scoring_income) {
            $total_income{$type} += $scoring_income{$type} * $mul;
        }        
    }

    return %total_income;
}

sub maybe_gain_power_from_cult {
    my ($faction_name, $old_value, $new_value) = @_;
    my $faction = $factions{$faction_name};

    if ($old_value <= 2 && $new_value > 2) {
        command $faction_name, "+1pw";
    }
    if ($old_value <= 4 && $new_value > 4) {
        command $faction_name, "+2pw";
    }
    if ($old_value <= 6 && $new_value > 6) {
        command $faction_name, "+2pw";
    }
    if ($old_value <= 9 && $new_value > 9) {
        command $faction_name, "+3pw";
    }
}

my @colors = qw(yellow brown black blue green gray red);
my %colors = ();
$colors{$colors[$_]} = $_ for 0..$#colors;

sub color_difference {
    my ($a, $b) = @_;
    my $diff = abs $colors{$a} - $colors{$b};

    if ($diff > 3) {
        $diff = 7 - $diff;
    }

    return $diff;
}

sub gain_power {
    my ($faction_name, $count) = @_;
    my $faction = $factions{$faction_name};

    for (1..$count) {
        if ($faction->{P1}) {
            $faction->{P1}--;
            $faction->{P2}++;
        } elsif ($faction->{P2}) {
            $faction->{P2}--;
            $faction->{P3}++;
        } else {
            return $_ - 1;
        }
    }

    return $count;
}

sub advance_track {
    my ($faction_name, $track_name, $track, $free) = @_;

    if (!$free) {
        pay $faction_name, $track->{advance_cost};
    }
    
    if ($track->{advance_gain}) {
        my $gain = $track->{advance_gain}[$track->{level}];
        gain $faction_name, $gain;
    }

    if (++$track->{level} > $track->{max_level}) {
        die "Can't advance $track_name from level $track->{level}\n"; 
    }
}

my %building_aliases = (
    DWELLING => 'D',
    'TRADING POST' => 'TP',
    TEMPLE => 'TE',
    STRONGHOLD => 'SH',
    SANCTUARY => 'SA',
    );

sub alias_building {
    my $type = shift;

    return $building_aliases{$type} // $type;
}

my %resource_aliases = (
    PRIEST => 'P',
    PRIESTS => 'P',
    POWER => 'PW',
    WORKER => 'W',
    WORKERS => 'W',
    COIN => 'C',
    COINS => 'C',
);

sub alias_resource {
    my $type = shift;

    return $resource_aliases{$type} // $type;
}

sub adjust_resource {
    my ($faction_name, $type, $delta) = @_;
    my $faction = $factions{$faction_name};

    $type = alias_resource $type;

    if ($type eq 'GAIN_SHIP') {
        for (1..$delta) {
            my $track = $faction->{ship};
            my $gain = $track->{advance_gain}[$track->{level}];
            gain $faction_name, $gain;
            $track->{level}++
        }
        $type = '';
    } elsif ($type eq 'PW') {
        if ($delta > 0) {
            gain_power $faction_name, $delta;
            $type = '';
        } else {
            $faction->{P1} -= $delta;
            $faction->{P3} += $delta;
            $type = 'P3';
        }
    } else {
        my $orig_value = $faction->{$type};

        # Pseudo-resources not in the pool, but revealed by removing
        # buildings.
        if ($type !~ /^ACT.$/) {
            $pool{$type} -= $delta;
        }
        $faction->{$type} += $delta;

        if (exists $pool{$type} and $pool{$type} < 0) {
            die "Not enough '$type' in pool\n";
        }

        if ($type =~ /^FAV/) {
            if (!$faction->{GAIN_FAVOR}) {
                die "Taking favor tile not allowed\n";
            } else {
                $faction->{GAIN_FAVOR}--;
            }

            gain $faction_name, $tiles{$type}{gain};
        }

        if ($type =~ /^TW/) {
            gain $faction_name, $tiles{$type}{gain};
        }

        if (grep { $_ eq $type } @cults) {
            if ($faction->{CULT}) {
                $faction->{CULT} -= $delta;
            }

            my $new_value = $faction->{$type};
            maybe_gain_power_from_cult $faction_name, $orig_value, $new_value;
        }

        for (1..$delta) {
            maybe_score_current_score_tile $faction_name, $type;
            maybe_gain_faction_special $faction_name, $type;
        }
    }

    if ($type =~ /^BON/) {
        $faction->{C} += $map{$type}{C};
        $map{$type}{C} = 0;
    }


    if ($type and $faction->{$type} < 0) {
        die "Not enough '$type' in $faction_name\n";
    }
}

sub command {
    my ($faction_name, $command) = @_;
    my $faction = $faction_name ? $factions{$faction_name} : undef;

    if ($command =~ /^([+-])(\d*)(\w+)$/) {
        die "Need faction for command $command\n" if !$faction_name;
        my ($sign, $count) = (($1 eq '+' ? 1 : -1),
                              ($2 eq '' ? 1 : $2));
        my $delta = $sign * $count;
        my $type = uc $3;

        adjust_resource $faction_name, $type, $delta;        
    }  elsif ($command =~ /^build (\w+)$/) {
        die "Need faction for command $command\n" if !$faction_name;

        my $free = ($round == 0);
        my $where = uc $1;
        my $type = 'D';
        die "Unknown location '$where'\n" if !$map{$where};

        die "'$where' already contains a $map{$where}{building}\n"
            if $map{$where}{building};

        if ($faction->{FREE_D}) {
            $free = 1;
            $faction->{FREE_D}--;
        }

        advance_track $faction_name, $type, $faction->{buildings}{$type}, $free;

        maybe_score_favor_tile $faction_name, $type;
        maybe_score_current_score_tile $faction_name, $type;

        $map{$where}{building} = $type;
        my $color = $faction->{color};

        command $faction_name, "transform $where to $color";
    } elsif ($command =~ /^upgrade (\w+) to ([\w ]+)$/) {
        die "Need faction for command $command\n" if !$faction_name;

        my $free = 0;
        my $type = alias_building uc $2;
        my $where = uc $1;
        die "Unknown location '$where'\n" if !$map{$where};

        my $color = $faction->{color};
        die "$where has wrong color ($color vs $map{$where}{color})\n" if
            $map{$where}{color} ne $color;

        my %wanted_oldtype = (TP => 'D', TE => 'TP', SH => 'TP', SA => 'TE');
        my $oldtype = $map{$where}{building};

        if ($oldtype ne $wanted_oldtype{$type}) {
            die "$where contains ə $oldtype, wanted $wanted_oldtype{$type}\n"
        }

        my %leech = ();
        for my $adjacent (keys %{$map{$where}{adjacent}}) {
            if ($map{$adjacent}{building} and
                $map{$adjacent}{color} ne $color) {
                $leech{$map{$adjacent}{color}} +=
                    $faction->{buildings}{$map{$adjacent}{building}}{strength};
            }
        }

        if ($type eq 'TP') {
            if ($faction->{FREE_TP}) {
                $free = 1;
                $faction->{FREE_TP}--;
            } else {
                if (!keys %leech) {
                    my $cost = $faction->{buildings}{$type}{advance_cost}{C};
                    command $faction_name, "-${cost}c";
                }
            }
        }

        $faction->{buildings}{$oldtype}{level}--;
        advance_track $faction_name, $type, $faction->{buildings}{$type}, $free;

        maybe_score_favor_tile $faction_name, $type;
        maybe_score_current_score_tile $faction_name, $type;

        $map{$where}{building} = $type;
    } elsif ($command =~ /^send (p) to (\w+)$/) {
        die "Need faction for command $command\n" if !$faction_name;

        my $cult = uc $2;
        die "Unknown cult track $cult\n"
            if !grep { $_ eq $cult } @cults;

        my $gain = { $cult => 1 };
        for (1..4) {
            my $where = "$cult$_";
            if (!$map{$where}{building}) {
                $gain = $map{$where}{gain};
                delete $map{$where}{gain};
                $map{$where}{building} = 'P';
                $map{$where}{color} = $faction->{color};
                last;
            }
        }

        gain $faction_name, $gain;

        command $faction_name, "-p";
    } elsif ($command =~ /^convert (\d+)?\s*(\w+) to (\d+)?\s*(\w+)$/) {
        die "Need faction for command $command\n" if !$faction_name;

        my $from_count = $1 || 1;
        my $from_type = alias_resource uc $2;
        my $to_count = $3 || 1;
        my $to_type = alias_resource uc $4;

        my %exchange_rates = (
            PW => { C => 1, W => 3, P => 5 },
            W => { C => 1 },
            P => { C => 1, W => 1 },
            C => { VP => 3 }
        );

        if ($faction->{exchange_rates}) {
            for my $from_key (keys %{$faction->{exchange_rates}}) {
                my $from = $faction->{exchange_rates}{$from_key};
                for my $to_key (keys %{$from}) {
                    $exchange_rates{$from_key}{$to_key} = $from->{$to_key};
                }
            }
        }

        if ($faction->{CONVERT_W_TO_P}) {
            die "Can't convert more than 3 W to P\n" if $to_count > 3;
            $exchange_rates{W}{P} = 1;
            delete $faction->{CONVERT_W_TO_P};
        }

        die "Can't convert from $from_type to $to_type\n"
            if !$exchange_rates{$from_type}{$to_type};

        my $wanted_from_count =
            $to_count * $exchange_rates{$from_type}{$to_type};
        die "Conversion to $to_count $to_type requires $wanted_from_count $from_type, not $from_count\n"
            if  $wanted_from_count != $from_count;
        
        command $faction_name, "-$from_count$from_type";
        command $faction_name, "+$to_count$to_type";
    } elsif ($command =~ /^burn (\d+)$/) {
        die "Need faction for command $command\n" if !$faction_name;
        adjust_resource $faction_name, 'P2', -2*$1;
        adjust_resource $faction_name, 'P3', $1;
    } elsif ($command =~ /^leech (\d+)$/) {
        die "Need faction for command $command\n" if !$faction_name;
        my $pw = $1;
        my $actual_pw = gain_power $faction_name, $pw;
        my $vp = $actual_pw - 1;

        if ($actual_pw > 0) {
            command $faction_name, "-${vp}VP";
        }
    } elsif ($command =~ /^transform (\w+) to (\w+)$/) {
        my $where = uc $1;
        my $color = lc $2;
        if ($faction->{FREE_TF}) {
            command $faction_name, "-FREE_TF";            
        } else {
            my $color_difference = color_difference $map{$where}{color}, $color;

            if ($faction_name eq 'Giants' and $color_difference != 0) {
                $color_difference = 2;
            }

            command $faction_name, "-${color_difference}SHOVEL";
        } 

        $map{$where}{color} = $color;
    } elsif ($command =~ /^dig (\d+)/) {
        my $cost = $faction->{dig}{cost}[$faction->{dig}{level}];
        my $gain = $faction->{dig}{gain}[$faction->{dig}{level}];

        command $faction_name, "+${1}SHOVEL";
        pay $faction_name, $cost for 1..$1;
        gain $faction_name, $gain for 1..$1;
    } elsif ($command =~ /^bridge (\w+):(\w+)$/) {
        die "Need faction for command $command\n" if !$faction_name;

        my $from = uc $1;
        my $to = uc $2;
        $map{$from}{adjacent}{$to} = 1;
        $map{$to}{adjacent}{$from} = 1;

        push @bridges, {from => $from, to => $to, color => $faction->{color}};
    } elsif ($command =~ /^pass(?: (\w+))?$/) {
        die "Need faction for command $command\n" if !$faction_name;
        my $bon = $1;

        $faction->{passed} = 1;
        for (keys %{$faction}) {
            next if !$faction->{$_};

            my $pass_vp  = $tiles{$_}{pass_vp};
            if (/^BON/) {
                command $faction_name, "-$_";
            }

            if ($pass_vp) {
                for my $type (keys %{$pass_vp}) {
                    my $x = $pass_vp->{$type}[$faction->{buildings}{$type}{level}];
                    command $faction_name, "+${x}vp";
                }
            }                
        }
        if ($bon) {
            command $faction_name, "+$bon"
        }
    } elsif ($command =~ /^action (\w+)$/) {
        my $where = uc $1;
        my $name = $where;
        if ($where !~ /^ACT/) {
            $where .= "/$faction_name";
        }

        if ($actions{$name}) {
            pay $faction_name, $actions{$name}{cost};
            gain $faction_name, $actions{$name}{gain};
        } else {
            die "Unknown action $name\n";
        }

        if ($map{$where}{blocked}) {
            die "Action space $where is blocked\n"
        }
        $map{$where}{blocked} = 1;
    } elsif ($command =~ /^start$/) {
        $round++;

        for my $faction_name (@factions) {
            my $faction = $factions{$faction_name};
            die "Round $round income not taken for $faction_name\n" if
                !$faction->{income_taken};
            $faction->{income_taken} = 0;
            $faction->{passed} = 0 for keys %factions;
        }

        $map{$_}{blocked} = 0 for keys %map;
        for (1..9) {
            if ($pool{"BON$_"}) {
                $map{"BON$_"}{C}++;
            }
        }
    } elsif ($command =~ /^setup (\w+)$/) {
        setup $1;
    } elsif ($command =~ /delete (\w+)$/) {
        delete $pool{uc $1};
    } elsif ($command =~ /^income$/) {
        die "Need faction for command $command\n" if !$faction_name;

        die "Taking income twice for $faction_name\n" if
            $faction->{income_taken};

        my %income = faction_income $faction_name;
        gain $faction_name, \%income;
        
        $faction->{income_taken} = 1
    } elsif ($command =~ /^advance (ship|dig)/) {
        die "Need faction for command $command\n" if !$faction_name;

        my $type = lc $1;
        my $track = $faction->{$type};

        advance_track $faction_name, $type, $track, 0;
    } elsif ($command =~ /^score (.*)/) {
        my $setup = uc $1;
        @score_tiles = split /,/, $setup;
        die "Invalid scoring tile setup: $setup\n" if @score_tiles != 6;
    } else {
        die "Could not parse command '$command'.\n";
    }
}

sub handle_row {
    local $_ = shift;

    # Comment
    if (s/#(.*)//) {
        push @ledger, { comment => $1 };
    }

    s/\s+/ /g;

    my $prefix = '';

    if (s/^(.*?)://) {
        $prefix = lc $1;
    }

    my @commands = split /[.]/, $_;

    for (@commands) {
        s/^\s+//;
        s/\s+$//;
        s/(\W)\s(\w)/$1$2/g;
        s/(\w)\s(\W)/$1$2/g;
    }

    @commands = grep { /\S/ } @commands;

    return if !@commands;

    if ($factions{$prefix} or $prefix eq '') {
        my @fields = qw(VP C W P P1 P2 P3 PW
                        FIRE WATER EARTH AIR CULT);
        my %old_data = map { $_, $factions{$prefix}{$_} } @fields; 

        for my $command (@commands) {
            command $prefix, lc $command;
        }

        my %new_data = map { $_, $factions{$prefix}{$_} } @fields;

        if ($prefix) {
            $old_data{PW} = $old_data{P2} + 2 * $old_data{P3};
            $new_data{PW} = $new_data{P2} + 2 * $new_data{P3};

            $old_data{CULT} = sum @old_data{@cults};
            $new_data{CULT} = sum @new_data{@cults};

            my %delta = map { $_, $new_data{$_} - $old_data{$_} } @fields;
            my %pretty_delta = map { $_, { delta => $delta{$_},
                                           value => $new_data{$_} } } @fields;
            $pretty_delta{PW}{value} = sprintf "%d/%d/%d",  $new_data{P1}, $new_data{P2}, $new_data{P3};

            $pretty_delta{CULT}{value} = sprintf "%d/%d/%d/%d", $new_data{FIRE}, $new_data{WATER}, $new_data{EARTH}, $new_data{AIR};

            my $warn = '';
            if ($factions{$prefix}{SHOVEL}) {
                 $warn = "Unused shovels for $prefix\n";
            }

            if ($factions{$prefix}{FREE_TF}) {
                $warn = "Unused free terraform for $prefix\n";
            }

            if ($factions{$prefix}{FREE_TP}) {
                $warn = "Unused free trading post for $prefix\n";
            }

            if ($factions{$prefix}{CULT}) {
                $warn = "Unused cult advance for $prefix\n";
            }

            if ($factions{$prefix}{GAIN_FAVOR}) {
                $warn = "favor not taken by $prefix\n";
            }

            push @ledger, { faction => $prefix,
                            warning => $warn,
                            commands => (join ". ", @commands),
                            map { $_, $pretty_delta{$_} } @fields};

        }
    } else {
        die "Unknown prefix: '$prefix' (expected one of ".
            (join ", ", keys %factions).
            ")\n";
    }
}

sub print_json {
    my $out = encode_json {
        order => \@factions,
        map => \%map,
        factions => \%factions,
        pool => \%pool,
        bridges => \@bridges,
        ledger => \@ledger,
        error => \@error,
        # tiles => \%tiles,
        towns => { map({$_, $tiles{$_}} grep { /^TW/ } keys %tiles ) },
        score_tiles => [ map({$tiles{$_}} @score_tiles ) ],
        bonus_tiles => { map({$_, $tiles{$_}} grep { /^BON/ } keys %tiles ) },
        favors => { map({$_, $tiles{$_}} grep { /^FAV/ } keys %tiles ) },
    };

    print $out;
}

while (<>) {
    eval { handle_row $_ };
    if ($@) {
        chomp;
        push @error, "Error on line $. [$_]:";
        push @error, "$@\n";
        last;
    }
}

if ($round > 0) {
    for my $faction (@factions) {
        $factions{$faction}{income} = { faction_income $faction };
    }

    for (0..($round-2)) {
        $tiles{$score_tiles[$_]}->{old} = 1;
    }

    current_score_tile->{active} = 1;
    $tiles{$score_tiles[-1]}->{income_display} = '';
}

for my $faction (@factions) {
    delete $factions{$faction}{buildings};
}

print_json;

if (@error) {
    print STDERR $_ for @error;
    exit 1;
}
