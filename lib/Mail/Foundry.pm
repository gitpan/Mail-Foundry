package Mail::Foundry;

use 5.008001;
use strict;
use warnings;

our $VERSION = '0.08';
our $CVSID   = '$Id: Foundry.pm,v 1.5 2007/07/11 18:19:53 scott Exp $';

use LWP::UserAgent ();
use URI::Escape 'uri_escape';
use HTML::Form ();

######################################################################
######################################################################
##
## As with all web-interfaces, this may change during a vendor update,
## or may change when we reach a certain number of accounts (e.g., the
## web interface begins to split into pages of 100 or 1000 domains
## each). Be prepared to make some changes.
##
######################################################################
######################################################################

## NOTE: This is an inside-out object; remove members in
## NOTE: the DESTROY() sub if you add additional members.
my %foundry   = ();
my %username  = ();
my %password  = ();
my %ua        = ();
my %agent     = ();
my %errors    = ();
my %err_pages = ();

sub new {
    my $class = shift;
    my %args  = @_;

    my $self = bless \(my $ref), $class;
    $args{foundry}  ||= '';
    $args{username} ||= '';
    $args{password} ||= '';
    $args{agent}    ||= 'perl/Mail-Foundry $VERSION';

    $foundry{$self}  = $args{foundry};
    $username{$self} = $args{username};
    $password{$self} = $args{password};
    $agent{$self}    = $args{agent};
    $errors{$self}   = [];
    $err_pages{$self} = [];

    return $self;
}

sub connect {
    my $self = shift;
    my %args = @_;

    exists $args{foundry}  and $foundry  {$self} = $args{foundry};
    exists $args{username} and $username {$self} = $args{username};
    exists $args{password} and $password {$self} = $args{password};
    exists $args{agent}    and $agent    {$self} = $args{agent};

    $ua{$self} = LWP::UserAgent->new;
    $ua{$self}->agent($agent{$self});
    $ua{$self}->cookie_jar({});

    my $uname = uri_escape($username{$self});
    my $upass = uri_escape($password{$self});

    ## authenticate
    my $req = HTTP::Request->new( POST => "http://$foundry{$self}/checklogin.phtml" );
    $req->content_type( 'application/x-www-form-urlencoded' );
    $req->content( "uname=$uname&passwd=$upass" );
    my $res = $ua{$self}->request($req);
    unless( $res->code == 302 ) {
	$self->errors("Failure: " . $res->code . ': ' . $res->message);
	$self->err_pages($res);
	return;
    }

    return 1;
}

sub add_user {
    my $self = shift;
    my %args = @_;

    unless( $args{username} && $args{password} ) {
	$self->errors( "username and password parameters are required for add_user()" );
	return;
    }

    $args{firstname} ||= 'Fulano';
    $args{lastname}  ||= 'Talyqual';

    my $res = $ua{$self}->request
	(HTTP::Request->new(GET => "http://$foundry{$self}/adminuser_edit.phtml"));

    my $form = $self->_get_form($res, qr(\badminuser_edit\.phtml))
	or return;

    $form->value( username => $args{username} );
    $form->value( passwd   => $args{password} );
    $form->value( passwd2  => $args{password} );
    $form->value( level    => 'domain' );
    $form->value( fname    => $args{firstname} );
    $form->value( lname    => $args{lastname} );

    ## submit new user
    $res = $ua{$self}->request( $form->click('submit') );
  CHECK_CODE: {
	unless( $res->code == 302 ) {
	    if( $res->content =~ /username '$args{username}' already exists/i ) {
		last CHECK_CODE;
	    }

	    $self->errors( "Couldn't add new user: " . $res->code . ": " . $res->message );
	    $self->err_pages($res);
	    return;
	}
    }

    my $user_id = $self->_get_user_id($args{username})
	or return;

    my $domain_id = $self->_get_domain_id($user_id, $args{domain})
	or return;

    ## fetch the domain page
    $res = $ua{$self}->request( HTTP::Request->new(GET => "http://$foundry{$self}/adminuser_domains.phtml?id=$user_id") );

    $form = $self->_get_form($res, qr(\badminuser_domains\.phtml))
	or return;

    ## check the value
    $self->_check_form_checkbox($form, 'did[]', $domain_id)
	or do {
	    $self->error("Could not find checkbox value '$domain_id'.");
	    $self->err_pages($res);
	    return;
	};

    $res = $ua{$self}->request( $form->click('submit') );
    unless( $res->code == 302 ) {
	$self->errors( "Domain attachment to user failed." );
	$self->err_pages($res);
	return;
    }

    return 1;
}

sub update_user {
    my $self = shift;
    my %args = @_;

    my $user_id = $self->_get_user_id($args{username})
      or return;


  my $res = $ua{$self}->request( HTTP::Request->new( GET => "http://$foundry{$self}/adminuser_edit.phtml?id=$user_id" ) );
    my $form = $self->_get_form($res, qr(\badminuser_edit\.phtml))
      or return;

    $form->value( username => $args{newusername} )  if $args{newusername};
    $form->value( fname    => $args{firstname} )    if $args{firstname};
    $form->value( lname    => $args{lastname} )     if $args{lastname};
    $form->value( level    => $args{level} )        if $args{level};
    $form->value( passwd   => $args{password} )     if $args{password};
    $form->value( passwd2  => $args{password} )     if $args{password};

    $res = $ua{$self}->request( $form->click('submit') );

    unless( $res->content =~ /Update Successful/i ) {
	$self->errors( "Could not update the username changes for '$args{username}'" );
	$self->err_pages($res);
	return;
    }

    return 1;
}

sub delete_user {
    my $self = shift;
    my %args = @_;

    my $user_id = $self->_get_user_id($args{username})
	or return;

    my $res = $ua{$self}->request( HTTP::Request->new( GET => "http://$foundry{$self}/adminuser_toggle.phtml?action=delete&id=$user_id" ) );
    my $form = $self->_get_form($res, qr(\badminuser_toggle\.phtml))
	or return;

    $res = $ua{$self}->request( $form->click('confirm') );
    unless( $res->code == 302 ) {
	$self->errors( "Could not delete user '$args{username}'." );
	$self->err_pages($res);
	return;
    }

    return 1;
}

sub add_domain {
    my $self = shift;
    my %args = @_;

    $args{domain} ||= '';
    $args{server} ||= '';

    unless( $args{domain} && $args{server} ) {
	$self->errors( "domain and server parameters are required for add_domain()" );
	return;
    }

    $args{priority} = ( exists $args{priority}
			? $args{priority}
			: 10 );
    $args{port} ||= 25;
    $args{max_msg_size} = ( exists $args{max_msg_size}
			    ? $args{max_msg_size}
			    : 0 );
    $args{virus} = ( exists $args{virus}
		     ? $args{virus}
		     : 'enabled' );

    my $req = HTTP::Request->new(POST => "http://$foundry{$self}/domain_edit.phtml");
    $req->content_type( 'application/x-www-form-urlencoded' );
    $req->content( "qs=&page=1&domain=$args{domain}&max_msg_size=$args{max_msg_size}&virus=$args{virus}&submit=submit" );
    my $res = $ua{$self}->request($req);

    ## check for some common error conditions
    if( $res->content =~ /an error occurred/i ) {
	if( $res->content =~ /$args{domain} already exists/ ) {
	    $self->errors( "The domain already exists." );
	    $self->err_pages($res);
	    return;
	}
    }

    ## FIXME: should check the HTTP return code here

    ## verify that we added the domain
    unless( $res->content =~ /current domain mappings for $args{domain}/i ) {
	$self->errors( "Could not verify that the domain was added." );
	$self->err_pages($res);
	return;
    }

    ## now use the form methods to click it
    my $form = $self->_get_form($res, qr(\bdomain_edit\.phtml))
      or return;

    ## does server already exist in the list?
    if( my $server_id = _get_value_from_row( _find_table_row($res->content, "\Q$args{server}\E") ) ) {
	$self->_check_form_checkbox($form, 'id[]', $server_id)
	  or do {
	      $self->error("Could not find checkbox value '$server_id'.");
	      $self->err_pages($res);
	      return;
	  };

	my $res = $ua{$self}->request( $form->click('submit') );

	unless( $res->content =~ /Update Successful/i ) {
	    $self->errors( "Could not update the SMTP association settings." );
	    $self->err_pages($res);
	    return;
	}

	return 1;
    }

    ## add the server and link to it
    $self->_check_form_checkbox($form, 'id[]', 'new');
    $form->value('new_server'    => $args{server} );
    $form->value('priority[new]' => $args{priority} );
    $form->value('port[new]'     => $args{port} );

    undef $res;
    $res = $ua{$self}->request( $form->click('submit') );

    unless( $res->content =~ /Update Successful/i ) {
	$self->errors( "Could not add new server to SMTP destinations." );
	$self->err_pages($res);
	return;
    }

    return 1;
}

## this will add the domain if it doesn't already exist, otherwise it
## will just update the domain with the new information.
sub update_domain {
    my $self = shift;
    my %args = @_;

    unless( $args{domain} ) {
	$self->errors( "domain parameter required for update_domain()" );
	return;
    }

    my $req = HTTP::Request->new(GET => "http://$foundry{$self}/smtp_configuration.phtml?search_str=$args{domain}&section=acptdom");

    my $res = $ua{$self}->request($req);
    unless( $res->code == 200 ) {
	$self->errors( "Failure: " . $res->code . ": " . $res->message );
	$self->err_pages($res);
	return;
    }

    ## find the domain id
    my $account_id = _get_value_from_row( _find_table_row($res->content, "\Q$args{domain}\E") );
    unless( $account_id ) {
	$self->errors("Could not get account id from server.");
	return;
    }

    $res = $ua{$self}->request
      (HTTP::Request->new(GET => "http://$foundry{$self}/domain_edit.phtml?id=$account_id"));

    my $form = $self->_get_form($res, qr(\bdomain_edit\.phtml))
      or return;

    $form->value( did          => $account_id );
    $form->value( domain       => $args{domain} );
    $form->value( page         => 1 );
    $form->value( max_msg_size => $args{max_msg_size} ) if $args{max_msg_size};
    $form->value( virus        => $args{virus} )        if $args{virus};

    $res = $ua{$self}->request( $form->click('submit') );
  CHECK_CODE: {
	## FIXME: check error code
	last CHECK_CODE;
    }

    if( $args{server} || $args{priority} || $args{port} ) {
	$form = $self->_get_form($res, qr(\bdomain_edit\.phtml))
	  or return;

	## uncheck existing SMTP server(s)
	for my $input ( $form->find_input('id[]', 'checkbox') ) {
	    $input->value(undef);
	}

	if( my $server_id = _get_value_from_row( _find_table_row($res->content, "(?:<b>)?\Q$args{server}\E(?:</b>)?") ) ) {
	    $self->_check_form_checkbox($form, 'id[]', $server_id)
	      or do {
		  $self->error("Could not find checkbox value '$server_id'.");
		  $self->err_pages($res);
		  return;
	      };

	    my $res = $ua{$self}->request( $form->click('submit') );

	    unless( $res->content =~ /Update Successful/i ) {
		$self->errors( "Could not update the SMTP association settings." );
		$self->err_pages($res);
		return;
	    }

	    return 1;
	}

	## a new server not listed above
	## add the server and link to it
	$self->_check_form_checkbox($form, 'id[]', 'new');
	$form->value('new_server'    => $args{server} );
	$form->value('priority[new]' => $args{priority} || 10 );
	$form->value('port[new]'     => $args{port} || 25 );

	## submit the changes on page 2
	undef $res;
	$res = $ua{$self}->request( $form->click('submit') );

	unless( $res->content =~ /Update Successful/i ) {
	    $self->errors( "Could not add new server to SMTP destinations." );
	    $self->err_pages($res);
	    return;
	}
    }

    ## FIXME: would be good to delete any SMTP servers that have no
    ## FIXME: domains pointing to them. Someday.

    return 1;
}

sub delete_domain {
    my $self = shift;
    my %args = @_;

    unless( $args{domain} ) {
	$self->errors( "domain parameter required for delete_domain()" );
	return;
    }

    my $req = HTTP::Request->new(GET => "http://$foundry{$self}/smtp_configuration.phtml?search_str=$args{domain}&section=acptdom");

    my $res = $ua{$self}->request($req);
    unless( $res->code == 200 ) {
	$self->errors( "Failure: " . $res->code . ": " . $res->message );
	$self->err_pages($res);
	return;
    }

    ## find the domain id
    my $account_id = _get_value_from_row( _find_table_row($res->content, "\Q$args{domain}\E") );
    unless( $account_id ) {
	$self->errors("Could not get account id from server.");
	return;
    }

    ## make the delete request
    $req = HTTP::Request->new(POST => "http://$foundry{$self}/domain_toggle.phtml");
    $req->content_type( 'application/x-www-form-urlencoded' );
    $req->content( "id[]=$account_id&delete=Delete" );
    $res = $ua{$self}->request($req);

    ## check the response for a dangling server
    unless( $res->content =~ /successfully deleted the following domains/i ) {
	$self->errors("The domain could not be verified as deleted.");
	$self->err_pages($res);
	return;
    }

    return 1;
}

sub spam_settings {
    my $self = shift;
    my %args = @_;
    my $domain = delete $args{domain};

    unless( $domain ) {
	$self->errors( "'domain' parameter required for spam_settings()" );
	return;
    }

    ## get account id
    my $account_id = $self->_get_account_from_page("http://$foundry{$self}/engine_config.phtml?section=spam", $domain)
	or return;

    ## follow the redirect
    my $res = $self->_do_redirect("http://$foundry{$self}/engine_config.phtml?section=spam")
	or return;

    ## return current settings
    unless( scalar keys %args ) {
	my $table = Mail::Foundry::Table::Utils::_get_inner_table
	    ($res->content, qr(following anti-spam settings));
	my @rows = Mail::Foundry::Table::Utils::_get_table_rows($table);

	my %settings = ();
      ROW: for my $row ( @rows ) {
	  CELL: for my $i (0..scalar(@$row)) {
                next unless $row->[$i];
		$row->[$i] =~ s/^[\r\n]+//g;
		$row->[$i] =~ s/[\r\n]+$//g;
	    }

	    ## look for specific settings we know about
	    next unless $row->[0];
	    if( $row->[0] =~ /Anti-Spam Check/ ) {
		$settings{status} = ( $row->[1] =~ /"enabled" selected/
				      ? 'enabled' : 'disabled' );
	    }
	    if( $row->[0] =~ /Anti-Spam Action/ ) {
		($settings{action}) = $row->[1] =~ /name="spam_act" value="(.+?)" checked>/;
	    }

	    if( $row->[0] =~ /Anti-Spam Action/ ) {
		($settings{modsub}) = $row->[1] =~ /name="s_modsub" value="([^\"]+)"/;
	    }

	    last ROW if $row->[0] && $row->[0] =~ /Per-User Overrides/;
	}

	return %settings;
    }

    ## post our spam settings changes
    my @forms = HTML::Form->parse( $res->content, $res->base);
    for my $form ( @forms ) {
        next unless $form->attr('name') && $form->attr('name') eq 'form';

        $form->value( spam_status => $args{spam_status} )
	    if exists $args{spam_status};

        $form->value( spam_act => $args{spam_act} )
	    if exists $args{spam_act};

        $form->value( s_modsub => $args{s_modsub} )
	    if exists $args{s_modsub};

        $form->value( redir_email => $args{redir_email} )
	    if exists $args{redir_email};

        $res = $ua{$self}->request( $form->click('submit') );
        last;
    }

    unless( $res->code == 200 ) {
	$self->errors( "Failure posting: " . $res->code . ": " . $res->message );
	$self->err_pages($res);
	return;
    }

    if( $res->content =~ /an error occurred/i ) {
	if( $res->content =~ /Invalid email address/i ) {
	    $self->errors( "Invalid email address specified for redirection" );
	    return;
	}

	elsif( $res->content =~ /specify a subject line/i ) {
	    $self->errors( "You must specify a subject line" );
	    return;
	}
    }

    unless( $res->content =~ /Updated? Successful(?:ly)?/i ) {
	$self->errors( "An error occurred. Could not update settings." );
	$self->err_pages($res);
	return;
    }

    return 1;
}

sub virus_settings {
    my $self = shift;
    my %args = @_;
    my $domain = delete $args{domain};

    unless( $domain ) {
	$self->errors( "'domain' parameter required for virus_settings()" );
	return;
    }

    ## get account id
    my $account_id = $self->_get_account_from_page("http://$foundry{$self}/engine_config.phtml?section=virus", $domain)
	or return;

    ## follow the redirect
    my $res = $self->_do_redirect("http://$foundry{$self}/engine_config.phtml?section=virus")
	or return;

    ## return current settings
    unless( scalar keys %args ) {
	my $table = Mail::Foundry::Table::Utils::_get_inner_table
	    ($res->content, qr(following anti-virus settings));
	my @rows = Mail::Foundry::Table::Utils::_get_table_rows($table);

	my %settings = ();
      ROW: for my $row ( @rows ) {
	  CELL: for my $i (0..scalar(@$row)) {
                next unless $row->[$i];
		$row->[$i] =~ s/^[\r\n]+//g;
		$row->[$i] =~ s/[\r\n]+$//g;
	    }

	    ## look for specific settings we know about
	    next unless $row->[0];
	    if( $row->[0] =~ /Anti-Virus Check/ ) {
		$settings{status} = ( $row->[1] =~ /"enabled" selected/
				      ? 'enabled' : 'disabled' );
	    }
	    if( $row->[0] =~ /Anti-Virus Action/ ) {
		($settings{action}) = $row->[1] =~ /name="virus_act" value="(.+?)" checked>/;
	    }

	    if( $row->[0] =~ /Anti-Virus Action/ ) {
		($settings{modsub}) = $row->[1] =~ /name="v_modsub" value="([^\"]+)"/;
	    }

	    if( $row->[0] =~ /Additional Options/ ) {
		($settings{notify_sender}) = ( $row->[1] =~ /name="notify_sender" value="1">/
					       ? 'enabled' : 'disabled' );
	    }

	    if( $row->[0] =~ /Additional Options/ ) {
		($settings{tell_me}) = ( $row->[1] =~ /name="tell_me" value="1">/
					       ? 'enabled' : 'disabled' );
	    }

	    last ROW if $row->[0] && $row->[0] =~ /Per-User Overrides/;
	}

	return %settings;
    }

    ## post our virus settings changes
    my @forms = HTML::Form->parse( $res->content, $res->base);
    for my $form ( @forms ) {
        next unless $form->attr('name') && $form->attr('name') eq 'form';

        $form->value( virus_status => $args{virus_status} )
	    if exists $args{virus_status};

        $form->value( virus_act => $args{virus_act} )
	    if exists $args{virus_act};

        $form->value( v_modsub => $args{v_modsub} )
	    if exists $args{v_modsub};

	$form->value( notify_sender => ($args{notify_sender} ? 1 : undef) )
	    if exists $args{notify_sender};

	$form->value( tell_me => ($args{tell_me} ? 1 : undef) )
	    if exists $args{tell_me};

        $res = $ua{$self}->request( $form->click('submit') );
        last;
    }

    unless( $res->code == 200 ) {
	$self->errors( "Failure posting: " . $res->code . ": " . $res->message );
	$self->err_pages($res);
	return;
    }

    if( $res->content =~ /an error occurred/i ) {
	if( $res->content =~ /specify a subject line/i ) {
	    $self->errors( "You must specify a subject line" );
	    return;
	}
    }

    unless( $res->content =~ /Updated? Successful(?:ly)?/i ) {
	$self->errors( "An error occurred. Could not update settings." );
	$self->err_pages($res);
	return;
    }

    return 1;
}

sub smtp_settings {
    my $self = shift;
    my %args = @_;
    my $domain = delete $args{domain};

    unless( $domain ) {
	$self->errors( "'domain' parameter required for smtp_settings()" );
	return;
    }

    ## get account id
    my $account_id = $self->_get_account_from_page("http://$foundry{$self}/smtp_configuration.phtml?section=routes", $domain)
	or return;

    ## follow the redirect
    my $res = $self->_do_redirect("http://$foundry{$self}/smtp_configuration.phtml?section=routes")
	or return;

    ## return current settings
    unless( scalar keys %args ) {
	my @rows = grep { scalar @$_ == 4 } Mail::Foundry::Table::Utils::_get_table_rows
	    (Mail::Foundry::Table::Utils::_get_inner_table
	     ($res->content, qr(select the SMTP servers)) );

	my @servers = ();

      ROW: for my $row ( @rows ) {
	CELL: for my $i (0..3) {
	    $row->[$i] =~ s/^[\r\n]+//g;
	    $row->[$i] =~ s/[\r\n]+$//g;
	    next ROW unless $row->[$i];
	}

	  next ROW if $row->[0] =~ /New Server/;

	  my $priority = $row->[3];
	  $priority =~ s/^.*<option value="(\d+)" selected>.*$/$1/s;
	  push @servers, { server   => $row->[1],
			   port     => $row->[2],
			   priority => $priority, };
      }

	return @servers;
    }

    ## post our virus settings changes
    my @forms = HTML::Form->parse( $res->content, $res->base);
    for my $form ( @forms ) {
	next unless $form->action =~ m#\broutes_edit.phtml#;

	if( $args{smtp_act} eq 'delete' ) {
	    ## FIXME: uncheck the box of $args{smtp_server}
	}

	elsif( $args{smtp_act} eq 'edit' ) {
	    ## FIXME: change the $args{smtp_priority} of $args{smtp_server}
	}

	elsif( $args{smtp_act} eq 'add' ) {
	    $form->value( new_smtp_server   => $args{smtp_server} );
	    $form->value( newdefport        => $args{smtp_port} );
	    $form->value( new_smtp_priority => $args{smtp_priority} );
	}

	else {
	    warn "Invalid action selected: '$args{smtp_act}'\n";
	    return;
	}

	## FIXME: working here

	$res = $ua{$self}->request( $form->click('submit') );
	last;
    }

    unless( $res->code == 200 ) {
	$self->errors( "Failure posting: " . $res->code . ": " . $res->message );
	$self->err_pages($res);
	return;
    }

    if( $res->content =~ /an error occurred/i ) {
	if( $res->content =~ /specify a subject line/i ) {
	    $self->errors( "You must specify a subject line" );
	    return;
	}
    }

    unless( $res->content =~ /Updated? Successful(?:ly)?/i ) {
	$self->errors( "An error occurred. Could not update settings." );
	$self->err_pages($res);
	return;
    }

    return 1;
}

sub errors {
    my $self = shift;

    if( @_ ) {
	push @{ $errors{$self} }, @_;
	return;
    }

    return @{ $errors{$self} };
}

sub clear_errors {
    my $self = shift;
    $errors{$self} = [];
}

sub err_pages {
    my $self = shift;

    if( @_ ) {
	push @{ $err_pages{$self} }, @_;
	return;
    }

    return @{ $err_pages{$self} };
}

sub clear_err_pages {
    my $self = shift;
    $err_pages{$self} = [];
}

sub DESTROY {
    my $self = $_[0];

    delete $foundry  {$self};
    delete $username {$self};
    delete $password {$self};
    delete $ua       {$self};
    delete $agent    {$self};
    delete $errors   {$self};

    my $super = $self->can("SUPER::DESTROY");
    goto &$super if $super;
}

sub _get_form {
    my $self   = shift;
    my $res    = shift;
    my $action = shift;

    my @forms = HTML::Form->parse( $res->content, $res->base );
    my $form;
    for my $frm ( @forms ) {
	next unless $frm->action =~ $action;
	$form = $frm;
	last
    }

    unless( $form ) {
	$self->errors( "Could not find form with action '$action'. Interface change?" );
    }

    return $form;
}

sub _check_form_checkbox {
    my $self = shift;
    my $form = shift;
    my $name = shift;
    my $value = shift;

    my $found = 0;

    for my $input ( $form->find_input($name, 'checkbox') ) {
	next unless ($input->possible_values)[1] eq $value;
	$input->check;
	$found = 1;
    }

    return $found;
}

sub _get_user_id {
    my $self = shift;
    my $username = shift;

    ## find this new user's id
    my $req = HTTP::Request->new(GET => "http://$foundry{$self}/system_configuration.phtml?search_str=$username&section=acctadmin");

    my $res = $ua{$self}->request($req);
    my $user_id = _get_value_from_row(_find_table_row($res->content, "\Q$username\E"))
	or do {
	    $self->errors( "Could not find user id for '$username'." );
	    return;
	};

    return $user_id;
}

sub _get_domain_id {
    my $self    = shift;
    my $user_id = shift;
    my $domain  = shift;

    my $res = $ua{$self}->request(HTTP::Request->new(GET => "http://$foundry{$self}/adminuser_domains.phtml?id=$user_id"));

    my $domain_id = _get_value_from_row(_find_table_row($res->content, "\Q$domain\E"))
	or do {
	    $self->errors( "Could not find domain '$domain' to attach. Domain missing?" );
	    return;
	};

    return $domain_id;
}

sub _find_table_row {
    return (_find_table_row_table(@_))[0];
}

## finds a table row whose <td>x</td> value matches the given
## expression
sub _find_table_row_table {
    my $str   = shift;
    my $find  = shift;
    my $chunk = '';
    my $o_str = $str;

    my $str_size = length($o_str);
    my $loop = 0;

  MATCH: {
      if( $loop and $str_size == length($str) ) {
	  warn "Loop detected. Exiting block.\n";
	  last MATCH;
      }
      $loop++;

      if( my( $t1, $t2, $t3 ) =
	  $str =~ m#(<tr[^>]*>)(.*?<td[^>]*>\s*$find\s*</td>.*?)(</tr>)#s ) {

	  ## found the right chunk
	  unless( $t2 =~ m#<tr[^>]*># ) {
              $chunk = $t1 . $t2 . $t3;
	      last MATCH;
	  }

	  ## found a <tr> before our data: carefully preserve trailing newline on $t2
	  if( my($tmp) = $t2 =~ m#(<tr[^>]*>.*?<td[^>]*>\s*$find\s*</td>.*?\s*)$#s ) {
	      $str = $tmp . $t3;
	      redo MATCH;
	  }

	  ## found a <tr> after our data
	  if( my($tmp) = $t2 =~ m#^(<tr[^>]*>.*?<td[^>]*>\s*$find\s*</td>.*?</tr>)#s ) {
	      $str = $t1 . $tmp;
	      redo MATCH;
	  }
      }
  }

    (my $left = $o_str) =~ s#\Q$chunk\E##;

    return ($chunk, $left);
}

sub _get_value_from_row {
    my $row = shift
	or return;
    my ($value) = $row =~ m#input type="?checkbox"? name="?.?id\[\]"? value="?(\d+)"?#;
    return $value;
}

sub _get_account_from_page {
    my $self = shift;
    my $page = shift;
    my $domain = shift;

    ## fetch the page so we can find the account id
    my $req = HTTP::Request->new(GET => $page);
    my $res = $ua{$self}->request($req);
    unless( $res->code == 200 ) {
	$self->errors( "Failure: " . $res->code . ": " . $res->message );
	return;
    }

    ## get account id from select list
    my $account_id = _get_value_from_select( $res->content, 'change_domain', $domain )
	or do {
	    $self->errors("Could not get account id from server.");
	    return;
	};

    ## change the domain form
    my @forms = HTML::Form->parse( $res->content, $res->base );
    for my $form ( @forms ) {
	next unless $form->action && $form->action =~ m#/change_domain.phtml#;

	$form->value(change_domain => $account_id);
	$res = $ua{$self}->request( $form->click('submit') );
	last;
    }

    unless( $res->code == 302 ) {
        $self->errors( "Failure: " . $res->code . ": " . $res->message );
        return;
    }

    return $account_id;
}

sub _do_redirect {
    my $self = shift;
    my $page = shift;

    my $req = HTTP::Request->new(GET => $page);
    my $res = $ua{$self}->request($req);
    unless( $res->code == 200 ) {
	$self->errors( "Failure: " . $res->code . ": " . $res->message );
	return;
    }

    return $res;
}

sub _get_value_from_select {
    my $str    = shift;
    my $select = shift;
    my $search = shift;
    my($value) = $str =~ m#<select name="\Q$select\E".*?>.*?<option value="(\d+)"[^>]*?>\Q$search\E</option>#s;
    return $value;
}

package Mail::Foundry::Table::Utils;

my $find_table = '';
my $handle_re  = '';
my $old_table  = '';

sub _get_inner_table {
    $old_table = shift;  ## package lexical
    my $table_re = shift;

    $handle_re = $table_re;
    my $p = HTML::Parser->new( api_version => 3,
			       start_h => [\&handle_table, "tagname,self,text"],
			       );

    my $copy = $old_table;
  DO_PARSE: {
      $p->parse($copy); ## sets $find_table

      unless( $find_table ) {
	  die "Could not find table.\n";
      }

      last DO_PARSE if $old_table eq $find_table;
      $copy = $old_table = $find_table;  ## save old copy for comparison next loop

      ## make this table pass through the table parser again
      $copy =~ s#^<table[^>]*>##m;
      $copy =~ s#</table[^>]*>$##m;

      redo DO_PARSE;
  }

    ## $find_table now contains the table we're looking for
    return $find_table;
}

sub _get_table_rows {
    my $table = shift;
    my $state = '';
    my @table = ();
    my @row   = ();
    my $cell  = '';

    my $p = HTML::Parser->new( api_version => 3 );

    $p->handler(   start => sub {
	my $tag = shift;

	$state = 'TABLE' if $tag eq 'table';
	$state = 'TR'    if $tag eq 'tr';
	if( $state eq 'TD' ) { $cell .= shift; }
	$state = 'TD'    if $tag eq 'td';
    }, "tagname,text" );

    $p->handler( default => sub { $cell .= shift if $state eq 'TD'; }, "text" );

    $p->handler(     end => sub {
	my $tag = shift;

	if( $tag eq 'td' ) {
	    $state = 'TR';
	    push @row, $cell;
	    $cell = '';
	}

	if( $tag eq 'tr' ) {
	    $state = 'TABLE';
	    push @table, [@row];
	    @row = ();
	}

	$state = ''      if $tag eq 'table';
    }, "tagname" );

    $p->parse($table);

    unless( scalar @table ) {
	die "Could not get rows from table\n";
    }

    return @table;
}

sub handle_table {
    my $tag  = shift;
    return unless $tag eq 'table';

    my $self = shift;
    my $table = shift;
    my $nested_table = 0;

    $self->handler(   start => sub { $table .= shift;
                                     $nested_table++ if shift eq 'table'; }, "text,tagname");
    $self->handler( default => sub { $table .= shift }, "text" );
    $self->handler(     end => sub { $table .= shift;
				     if( shift eq "table" ) {
					 if( $nested_table ) { $nested_table-- }
					 else {
					     ## found our table
					     if( $table =~ $handle_re ) {
						 $find_table = $table;
					     }
					     $self->handler( start => \&handle_table, "tagname,self,text" );
					     $self->handler( default => undef );
					     $self->handler( end => undef );
					 }
				     }
				 }, "text,tagname" );
}


1;
__END__

=head1 NAME

Mail::Foundry - Perl extension for talking to a MailFoundry appliance

=head1 SYNOPSIS

  use Mail::Foundry;
  my $mf = new Mail::Foundry(foundry => 'http://mailfoundry.domain.tld/',
                             username => 'admin',
                             password => '3u4ksufZeiu82');

  $mf->connect
    or die "Error connecting: " . join(' ', $mf->errors) . "\n";

  $mf->add_domain(domain => 'clientdomain.tld',
                  server => 'box24.hostdomain.tld');

  $mf->add_user( username => 'demo', password => 'mydemo',
                 domain => 'clientdomain.tld',
                 firstname => 'Joe', lastname => 'User' );

  $mf->delete_domain(domain => 'clientdomain.tld');

=head1 DESCRIPTION

B<Mail::Foundry> performs web requests via LWP to edit MaiFoundry
appliance settings, including adding, removing, and editing domain
settings.

=head2 add_domain

Adds a new domain to the server for processing and associates the
domain with an SMTP server (which the MailFoundry server will relay
to).

Parameters:

=over 4

=item domain

Required. Specify the domain name to scan mail for.

=item server

Required. Specify the name of the SMTP server that MailFoundry should
relay mail to after scanning. This is often the name of the physical
server where B<domain> is hosted.

=item priority

Optional. Specify the MX priority at which this SMTP server will
receive mail. Default: 10.

=item port

Optional. Specify the TCP port at which this SMTP server will receive
mail. Default: 25.

=item max_msg_size

Optional. Specify (in megabytes) the maximum message size MailFoundry
should accept for this domain. Default: 0 (no limit).

=item virus

Optional. Specify whether we should scan mail for viruses for this
domain. Values: 'enable', 'disable'. Default: 'enable'.

=back

=head2 delete_domain

Deletes a domain from the server; mail will no longer be accepted by
MailFoundry for this domain. Make sure that you have already pointed
the MX record to the new server at least 24h beforehand (or whatever
your MX TTL is set to).

Parameters:

=over 4

=item domain

Required. Specify the domain name to remove from the MailFoundry
server.

=back

=head2 update_domain

Same parameters as B<add_domain>

=head2 add_user

Adds a user to the Mail Foundry server for administering domain names.

Parameters

=over 4

=item username

The username with which this user logs into the Mail Foundry server.

=item password

The password with which this user logs into the Mail Foundry server.

=item firstname

First name of the login user.

=item lastname

Last name of the login user.

=item domain

The name of the domain this user will administer. The domain should
have already been added to the system.

=back

=head2 update_user

Updates current user information with the provided information.

Parameters: same as B<add_user> with the exception of an additional
B<newusername> which will change the username of the user to
B<newusername>.

Example:

  $mf->update_user( username => 'joe', password => 'mynewpassword' );

This will update joe's password to 'mynewpassword'.

=head2 delete_user

Deletes the user from the system, orphaning any domains previously
associated with this user.

Parameters:

=over 4

=item username

=back

=head2 spam_settings

This method returns the current anti-spam settings for this domain
when no parameters (other than B<domain>) are given. Otherwise, it
sets new anti-spam settings for the domain as specified in the options
below.

Parameters:

=over 4

=item domain

Required. The domain whose anti-spam settings you wish to modify.

=item spam_status

Optional. Enables or disables spam scanning for this domain.

Values: enabled | disabled

Default: enabled

=item spam_act

Optional. Determines the action to take when a spam message is
detected.

Values: addh | redir | modsub | quar | delete

  addh: add header
  redir: redirect spam to email address (specified in redir_email)
  modsub: modify subject (specified in modsub)
  quar: quarantine spam
  delete: delete spam

Default: modsub

=item s_modsub

Optional. Determines how the subject line is modified when a spam is
detected.

Default: '***SPAM***'

=item redir_email

Optional. Specifies an email address redirect spam to when detected.

Default: (none)

=back

=head2 virus_settings

This method returns the current anti-virus settings for this domain
when no parameters (other than B<domain>) are given. Otherwise, it
sets new anti-virus settings for the domain as specified in the
options below.

Parameters:

=over 4

=item domain

Required. The domain whose anti-virus settings you wish to modify.

=item virus_status

Optional. Enables or disables virus scanning for this domain.

Values: enabled | disabled

Default: enabled

=item virus_act

Optional. Determines the action to take when a virus is received.

Values: clean | modsub | quar | return | delete

  clean: clean the message, add 'X-MailFoundry: Virus' header, and deliver
  modsub: clean the message, modify the subject line to (v_modsub), and deliver
  quar: clean the message and quarantine it
  return: return the message to the sender
  delete: delete the message

=item v_modsub

Optional. Determines how the subject line is modified when a virus is
received.

Default: 'MAILFOUNDRY: VIRUS DETECTED'

=item notify_sender

Optional. If set, MailFoundry will send a notification to the sender
that a virus was found in an email.

Values: 0 | 1

=item tell_me

Optional. If set, MailFoundry will send a notification to the
recipient that a virus was found in an email.

Values: 0 | 1

=back

=head2 smtp_settings

This method returns the current SMTP settings for this domain when no
parameters (other than B<domain>) are given. Otherwise, it sets new
SMTP settings for the domain as specified in the options below.

=over 4

=item domain

Required. The domain whose SMTP settings you wish to view or modify.

=item server

FIXME: working here

=back

=head1 DIAGNOSTICS

When an error occurs internally, the specified action (e.g.,
add_domain(), delete_domain()) will return undef. You can check
diagnostic messages by reading the errors() method:

  $mf->add_domain('foo.tld', 'bar.mail.tld')
    or die "Could not add domain: " . join(' ', $mf->errors);

When an error condition occurs, it's probably best to manually login
to the MailFoundry server and verify what you wanted to accomplish
actually occurred.

Below are diagnostic messages grouped by their associated action.

=head2 add_domain()

=over 4

=item "The domain already exists."

The domain has already been added.

=item "Could not verify that the domain was added."

After attempting to add the domain, the mailfoundry server sent an
unrecognized response back.

=item "Could not update the SMTP association settings."

The domain was successfully added but the mailfoundry server sent an
unrecognized response when we tried to associate the domain with an
existing SMTP server.

=item "Could not add new server to SMTP destinations."

The domain was successfully added but the MailFoundry server sent an
unrecognized response when we tried to associate the domain with a new
SMTP server.

=back

=head2 delete_domain()

=over 4

=item "Failure: XXX: (some HTTP error message)"

An HTTP error occurred while requesting the delete domain page.

=item "Could not get account id from server."

The account id was not found on this server. This may indicate the
domain has already been deleted, or it may indicate that the account
id is listed on another page (which we haven't parsed).

=item "The domain could not be verified as deleted."

The domain may have been deleted, but we received an unexpected
response from the MailFoundry server.

=back

=head2 errors

Returns a list of current errors. Useful for debugging, for example:

  unless( $mf->connect ) {
    die "Could not connect to mf server: " . join(' ', $mf->errors) . "\n";
  }

=head2 err_pages

Returns a list of HTTP::Response objects (usually only the last one)
when an error condition or unexpected return value from the
MailFoundry server was received. Useful for debugging:

  unless( $mf->connect ) {
    my $err = join(' ', $mf->errors);
    unless( $err =~ /domain already exists/ ) {
      die "Unexpected HTML from MailFoundry: " . ($mf->err_pages)[0]->content;
    }
  }

If you encounter bugs with this module, the author may ask you to
return the results of B<err_pages>.

=head1 SEE ALSO

LWP(3), L<Mail::Postini>

=head1 AUTHOR

Scott Wiersdorf, E<lt>scott@perlcode.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2006 by Scott Wiersdorf

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.5 or,
at your option, any later version of Perl 5 you may have available.


=cut
