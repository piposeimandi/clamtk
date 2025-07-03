# ClamTk, copyright (C) 2004-2024 Dave M
#
# This file is part of ClamTk
# https://github.com/dave-theunsub/clamtk/
# https://gitlab.com/dave_m/clamtk/
#
# ClamTk is free software; you can redistribute it and/or modify it
# under the terms of either:
#
# a) the GNU General Public License as published by the Free Software
# Foundation; either version 1, or (at your option) any later version, or
#
# b) the "Artistic License".
package ClamTk::Update;

use Glib 'TRUE', 'FALSE';

$| = 1;

use Gtk3;
$| = 1;

use LWP::UserAgent;
use Locale::gettext;

# Keeping these global for easy messaging.
my $infobar;      # InfoBar for status
my $pb;           # ProgressBar for ... showing progress
my $liststore;    # Information on current and remote versions
my $iter_hash;    # Must be global to update sig area

my $updated = 0;

sub show_window {
    my $box = Gtk3::Box->new( vertical, 5 );
    $box->set_homogeneous( FALSE );

    my $top_box = Gtk3::Box->new( vertical, 5 );
    $top_box->set_homogeneous( FALSE );
    $box->pack_start( $top_box, TRUE, TRUE, 0 );

    my $scrolled = Gtk3::ScrolledWindow->new( undef, undef );
    $scrolled->set_policy( 'never', 'never' );
    $scrolled->set_shadow_type( 'etched-out' );
    $top_box->pack_start( $scrolled, FALSE, TRUE, 2 );

    # update available images:
    # gtk-yes = yes
    # gtk-no  = no
    # gtk-dialog-error = unknown

    $liststore = Gtk3::ListStore->new(
        # product, local version,
        'Glib::String', 'Glib::String', 'Glib::String',
    );

    # Product column
    my $view = Gtk3::TreeView->new_with_model( $liststore );
    $view->set_can_focus( FALSE );
    $scrolled->add( $view );
    my $column = Gtk3::TreeViewColumn->new_with_attributes(
        _( 'Product' ),
        Gtk3::CellRendererText->new,
        text => 0,
    );
    $column->set_alignment( 0.5 );
    $view->append_column( $column );

    # Installed version column
    $column = Gtk3::TreeViewColumn->new_with_attributes(
        _( 'Installed' ),
        Gtk3::CellRendererText->new,
        text => 1,
    );
    $column->set_alignment( 0.5 );
    $view->append_column( $column );

    # Date of signatures
    $column = Gtk3::TreeViewColumn->new_with_attributes(
        _( 'Date' ),
        Gtk3::CellRendererText->new,
        text => 2,
    );
    $column->set_alignment( 0.5 );
    $view->append_column( $column );

    # Get local information
    my $local_sig_version = ClamTk::App->get_local_sig_version();

    # Get date of signatures
    my $av_date = ClamTk::App->get_sigtool_info( 'date' );

    #<<<
    my @data = (
        {
            product => _( 'Antivirus signatures' ),
            local   => $local_sig_version,
            date    => $av_date,
        },
    );

    for my $item ( @data ) {
        my $iter = $liststore->append;

        # make a copy for updating
        $iter_hash = $iter;

        $liststore->set( $iter,
                0, $item->{ product },
                1, $item->{ local },
                2, $item->{ date },
        );
    }
    #>>>

    # Remove InfoBar and use only a full-width update button
    my $update_button;
    if ( ClamTk::Prefs->get_preference( 'Update' ) eq 'shared' ) {
        $update_button = Gtk3::Button->new(_( 'You are configured to automatically receive updates' ));
        $update_button->set_sensitive(0);
    } else {
        $update_button = Gtk3::Button->new(_( 'Check for updates' ));
        $update_button->set_hexpand(1);
        $update_button->set_halign('fill');
        $update_button->signal_connect( clicked => sub { update_signatures($update_button) } );
    }
    $box->pack_start( $update_button, FALSE, FALSE, 0 );
    # Remove any previous progress bar
    for my $child ($box->get_children) {
        if ($child->isa('Gtk3::ProgressBar')) {
            $box->remove($child);
        }
    }
    $view->columns_autosize();
    $box->show_all;
    return $box;
}


 sub get_remote_TK_version {
     my $url
         = 'https://raw.githubusercontent.com/dave-theunsub/clamtk/master/latest';

     $ENV{ HTTPS_DEBUG } = 1;

     my $ua = add_ua_proxy();

     my $response = $ua->get( $url );

     if ( $response->is_success ) {
         my $content = $response->content;
         chomp( $content );
         # warn "remote tk version = >$content<\n";
         return $content;
     } else {
         warn "failed remote tk check >", $response->status_line, "<\n";
         return '';
     }

     return '';
 }

sub update_signatures {
    my ($update_button) = @_;
    $update_button->set_label(_( 'Updating... 0%' ));
    $update_button->set_sensitive(0);

    my $freshclam = get_freshclam_path();
    if ( ClamTk::Prefs->get_preference( 'Update' ) eq 'single' ) {
        my $dbpath = ClamTk::App->get_path( 'localfreshclamconf' );
        if ( -e $dbpath ) {
            $freshclam .= " --config-file=$dbpath";
        }
    }

    my $update;
    my $update_sig_pid;
    eval {
        local $SIG{ ALRM } = sub {
            die "failed updating signatures (timeout)\n";
        };
        alarm 100;

        $update_sig_pid = open( $update, '-|', "$freshclam --stdout" );
        defined( $update_sig_pid )
            or do {
            $update_button->set_label(_( 'Error actualizando' ));
            return 0;
            };
        alarm 0;
    };
    if ( $@ && $@ eq "failed\n" ) {
        $update_button->set_label(_( 'Error actualizando' ));
        return 0;
    }

    my $percent = 0;
    my $last_percent = -1;
    while ( defined( my $line = <$update> ) ) {
        Gtk3::main_iteration while Gtk3::events_pending;
        chomp( $line );
        if ( $line =~ /\b(\d{1,3})%\b/ ) {
            $percent = $1;
            if ($percent ne $last_percent) {
                $update_button->set_label(_( 'Updating... ' ) . "$percent%");
                $last_percent = $percent;
            }
        }
        if ( $line =~ /failed/ ) {
            warn $line, "\n";
        } elsif ( $line =~ /Database test passed./ ) {
            warn "Database test passed.\n";
        } elsif ( $line =~ /^Downloading daily-(\d+).*?\u001b/ ) {
            my $new_daily = $1;
            $liststore->set( $iter_hash, 0, _( 'Antivirus signatures' ), 1, $new_daily, );
        } elsif ( $line =~ q#^Retrieving https://database.clamav.net/daily-(\d+).cdiff# ) {
            my $new_daily = $1;
            $liststore->set( $iter_hash, 0, _( 'Antivirus signatures' ), 1, $new_daily, );
        } elsif ( $line =~ /^Testing database/ ) {
            $update_button->set_label(_( 'Testing database...' ));
        } elsif ( $line =~ /^Downloading database patch # (\d+).*?$/ ) {
            my $new_daily = $1;
            $liststore->set( $iter_hash, 0, _( 'Antivirus signatures' ), 1, $new_daily, );
        } elsif ( $line =~ /Database updated/ ) {
            $update_button->set_label(_( 'Updating... 100%' ));
        } elsif (
            $line =~ /.*?bytecode.*?$/ && ( $line =~ /.*?up-to-date\.$/ || $line =~ /.*?up to date .*?/ || $line =~ /.*?updated\.$/ )
        ) {
            $update_button->set_label(_( 'Updating... 100%' ));
        } else {
            next;
        }
        Gtk3::main_iteration while Gtk3::events_pending;
    }
    my $local_sig_version = ClamTk::App->get_local_sig_version();
    $liststore->set( $iter_hash, 0, _( 'Antivirus signatures' ), 1, $local_sig_version, );
    Gtk3::main_iteration while Gtk3::events_pending;

    $update_button->set_label(_( 'Update completed!' ));
    $update_button->set_sensitive(0);
    $update_button->queue_draw;
    Gtk3::main_iteration while Gtk3::events_pending;
    return TRUE;
}

sub get_freshclam_path {
    my $paths = ClamTk::App->get_path( 'all' );

    my $command = $paths->{ freshclam };
    # If the user will update the signatures manually,
    # append the appropriate paths
    if ( ClamTk::Prefs->get_preference( 'Update' ) eq 'single' ) {
        $command
            .= " --datadir=$paths->{db} --log=$paths->{db}/freshclam.log";
    }
    # Add verbosity
    $command .= " --verbose";

    # Was the proxy option set?
    if ( ClamTk::Prefs->get_preference( 'HTTPProxy' ) ) {
        if ( ClamTk::Prefs->get_preference( 'HTTPProxy' ) == 2 ) {
            if ( -e $paths->{ localfreshclamconf } ) {
                $command .= " --config-file=$paths->{ localfreshclamconf }";
            }
        }
    }

    return $command;
}

sub set_infobar_text {
    my ( $type, $text ) = @_;
    # Fuerza el tipo a 'other' para evitar azul (info) o amarillo (warning)
    $infobar->set_message_type('other');
    # Intenta que el InfoBar sea completamente transparente o igual al fondo
    if ($infobar->can('override_background_color')) {
        $infobar->override_background_color('normal', undef); # GTK3: quita color explícito
    }
    if ($infobar->can('set_name')) {
        $infobar->set_name('clamtk-infobar');
    }
    my $content_area = $infobar->get_content_area;
    # Elimina todos los hijos previos
    for my $child ($content_area->get_children) {
        $content_area->remove($child);
    }
    # Agrega un nuevo label con el texto
    my $label = Gtk3::Label->new($text);
    $content_area->add($label);
    # No se fuerza color aquí, se deja a CSS
    $infobar->queue_draw;
    $label->show;
}

## MÉTODO NO UTILIZADO (comentado para limpieza y referencia)
# sub set_infobar_button {
#     my ( $stock_icon, $signal ) = @_;
#     if ( !$infobar->get_action_area->get_children ) {
#         $infobar->add_button( $stock_icon, $signal );
#     } else {
#         for my $child ( $infobar->get_action_area->get_children ) {
#             if ( $child->isa( 'Gtk3::Button' ) ) {
#                 $child->set_label( $stock_icon );
#             }
#         }
#     }
# }

## MÉTODO NO UTILIZADO (comentado para limpieza y referencia)
# sub destroy_button {
#     # Remove button from $infobar
#     for my $child ( $infobar->get_action_area->get_children ) {
#         if ( $child->isa( 'Gtk3::Button' ) ) {
#             $child->destroy;
#         }
#     }
# }

## MÉTODO NO UTILIZADO (comentado para limpieza y referencia)
# sub progress_timeout {
#     $pb->pulse;
#     return TRUE;
# }

sub add_ua_proxy {
    my $agent = LWP::UserAgent->new( ssl_opts => { verify_hostname => 1 } );
    $agent->timeout( 20 );

    $agent->protocols_allowed( [ 'http', 'https' ] );

    if ( ClamTk::Prefs->get_preference( 'HTTPProxy' ) ) {
        if ( ClamTk::Prefs->get_preference( 'HTTPProxy' ) == 1 ) {
            $agent->env_proxy;
        } elsif ( ClamTk::Prefs->get_preference( 'HTTPProxy' ) == 2 ) {
            my $path = ClamTk::App->get_path( 'db' );
            $path .= '/local.conf';
            my ( $url, $port );
            if ( -e $path ) {
                if ( open( my $FH, '<', $path ) ) {
                    while ( <$FH> ) {
                        if ( /HTTPProxyServer\s+(.*?)$/ ) {
                            $url = $1;
                        }
                        last
                            if ( !$url );
                        if ( /HTTPProxyPort\s+(\d+)$/ ) {
                            $port = $1;
                        }
                    }
                    close( $FH );
                    $ENV{ HTTPS_PROXY }                  = "$url:$port";
                    $ENV{ HTTP_PROXY }                   = "$url:$port";
                    $ENV{ PERL_LWP_SSL_VERIFY_HOSTNAME } = 0;
                    $ENV{ HTTPS_DEBUG }                  = 1;
                    $agent->proxy( http  => "$url:$port" );
                    $agent->proxy( https => "$url:$port" );
                }
            }
        }
    }
    return $agent;
}

1;
