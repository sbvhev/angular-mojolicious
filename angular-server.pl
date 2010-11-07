#!/usr/bin/env perl

use lib 'common/mojo/lib';

use Mojolicious::Lite;
use Data::Dump qw(dump);
use Time::HiRes;
use Clone qw(clone);

sub new_uuid { Time::HiRes::time * 100000 }

# based on
# http://docs.getangular.com/REST.Basic
# http://angular.getangular.com/data

our $data = {
	'Cookbook' => {
		test => [
				{ '$id' => 1, foo => 1, bar => 2, baz => 3 },
				{ '$id' => 2, foo => 1                     },
				{ '$id' => 3,           bar => 2           },
				{ '$id' => 4,                     baz => 3 },
		],
	},
	'AddressBook' => {
		people => [
			{name=>'Misko'},
			{name=>'Igor'},
			{name=>'Adam'},
			{name=>'Elliott'}
		]
	}
};

my $couchdb = 'http://localhost:5984';
our $couchdb_rev;

sub _couchdb_put {
	my ( $self, $database, $entity, $id, $hash ) = @_;

	my $data = clone $hash;
	delete $data->{_id}; # CouchDB doesn't like _ prefixed attributes, and will generate it's own _id
	$data->{'$entity'} = $entity;
	if ( my $rev = $couchdb_rev->{$database}->{$entity}->{$id} ) {
		$data->{_rev} = $rev;
	}

	my $json = Mojo::JSON->new->encode( $data );
	my $client = Mojo::Client->new;

	warn "# _couchdb_put $couchdb/$database/$entity.$id = $json";
	$client->put( "$couchdb/$database/$entity.$id" => $json => sub {
		my ($client,$tx) = @_;
		if ($tx->error) {
			die $tx->error;
		}
		my $response = $tx->res->json;
		warn "## CouchDB response ",dump($response);
		$couchdb_rev->{$database}->{$entity}->{$id} = $response->{rev} || die "no rev";
	})->process;
}

sub _couchdb_get {
	my ( $self, $database, $entity, $id ) = @_;
	my $client = Mojo::Client->new;
	my $return = $client->get( "$couchdb/$database/$entity.$id" )->res->json;
	warn "# _couchdb_get $couchdb/$database/$entity.$id = ",dump($return);
	return $return;
}

our $id2nr;


sub _render_jsonp {
	my ( $self, $json ) = @_;
#warn "## _render_json ",dump($json);
	my $data = $self->render( json => $json, partial => 1 );
warn "## _render_json $data";
	if ( my $callback = $self->param('callback') ) {
		$data = "$callback($data)";
	}
	$self->render( data => $data, format => 'js' );
}

#get '/' => 'index';

get '/_replicate' => sub {
	my $self = shift;

	if ( my $from = $self->param('from') ) {
		my $got = $self->client->get( $from )->res->json;
		warn "# from $from ",dump($got);
		_render_jsonp( $self,  $got );

		my $database = $got->{name};
		my $entities = $got->{entities};

		if ( $database && $entities ) {
			foreach my $entity ( keys %$entities ) {
				my $url = $from;
				$url =~ s{/?$}{/}; # add slash at end
				$url .= $entity;
				my $e = $self->client->get( $url )->res->json;
				warn "# replicated $url ", dump($e);
				$data->{$database}->{$entity} = $e;
				delete $id2nr->{$database}->{$entity};
			}
		}
	}
};

get '/_data' => sub {
	my $self = shift;
	_render_jsonp( $self, $data )
};

get '/data/' => sub {
	my $self = shift;
	_render_jsonp( $self,  [ keys %$data ] );
};

get '/data/:database' => sub {
	my $self = shift;
	my $database = $self->param('database');
	my $list_databases = { name => $database };
	foreach my $entity ( keys %{ $data->{ $database }} ) {
warn "# entry $entity ", dump( $data->{$database}->{$entity} );
		my $count = $#{ $data->{$database}->{$entity} } + 1;
		$list_databases->{entities}->{$entity} = $count;
		$list_databases->{document_count} += $count;
	}
	warn dump($list_databases);
	_render_jsonp( $self,  $list_databases );
};

get '/data/:database/:entity' => sub {
	my $self = shift;
	_render_jsonp( $self,  $data->{ $self->param('database') }->{ $self->param('entity' ) } );
};

get '/data/:database/:entity/:id' => sub {
    my $self = shift;

	my $database = $self->param('database');
	my $entity   = $self->param('entity');
	my $id       = $self->param('id');

	my $e = $data->{$database}->{$entity};

	if ( ! $e ) {
		$e = _couchdb_get( $self, $database, $entity, $id );
		return _render_jsonp( $self, $e );
	}

	if ( ! defined $id2nr->{$database}->{$entity}  ) {
		foreach my $i ( 0 .. $#$e ) {
			$id2nr->{$database}->{$entity}->{ $e->[$i]->{'$id'} } = $i;
		}
	}

	if ( exists $id2nr->{$database}->{$entity}->{$id} ) {
		my $nr = $id2nr->{$database}->{$entity}->{$id};
		warn "# entity $id -> $nr\n";
		_render_jsonp( $self,  $data->{$database}->{$entity}->[$nr] );
	} else {
		die "no entity $entity $id in ", dump( $id2nr->{$database}->{$entity} );
	}
};

any [ 'post' ] => '/data/:database/:entity' => sub {
	my $self = shift;
	my $json = $self->req->json;
	my $id = $json->{'$id'} # XXX we don't get it back from angular.js
		|| $json->{'_id'}  # so we use our version
		|| new_uuid;
	warn "## $id body ",dump($self->req->body, $json);
	die "no data" unless $data;

	$json->{'$id'} ||= $id;	# angular.js doesn't resend this one
	$json->{'_id'} = $id;	# but does this one :-)

	my $database = $self->param('database');
	my $entity   = $self->param('entity');

	my $nr = $id2nr->{$database}->{$entity}->{$id};
	if ( defined $nr ) {
		$data->{$database}->{$entity}->[$nr] = $json;
		warn "# update $nr $id ",dump($json);
	} else {
		push @{ $data->{$database}->{$entity} }, $json;
		my $nr = $#{ $data->{$database}->{$entity} };
		$id2nr->{$database}->{$entity}->{$id} = $nr;
		warn "# added $nr $id ",dump($json);
	}

	_couchdb_put( $self, $database, $entity, $id, $json );

	_render_jsonp( $self,  $json );
};

get '/demo/:groovy' => sub {
	my $self = shift;
    $self->render(text => $self->param('groovy'), layout => 'funky');
};

get '/' => sub { shift->redirect_to('/Cookbook') };
get '/Cookbook' => 'Cookbook';
get '/Cookbook/:example' => sub {
	my $self = shift;
	$self->render( "Cookbook/" . $self->param('example'), layout => 'angular' );
};

get '/conference/:page' => sub {
	my $self = shift;
	$self->render( "conference/" . $self->param('page'), layout => 'angular' );
};

app->start;
__DATA__

@@ index.html.ep
% layout 'funky';
Yea baby!

@@ layouts/funky.html.ep
<!doctype html><html>
    <head><title>Funky!</title></head>
    <body><%== content %></body>
</html>

@@ layouts/angular.html.ep
<!DOCTYPE HTML>
<html xmlns:ng="http://angularjs.org">
  <head>
   <meta charset="utf-8">
% my $ANGULAR_JS = $ENV{ANGULAR_JS} || ( -e 'public/angular/build/angular.js' ? '/angular/build/angular.js' : '/angular/src/angular-bootstrap.js' );
    <script type="text/javascript"
         src="<%== $ANGULAR_JS %>" ng:autobind></script>
  </head>
  <body><%== content %></body>
</html>
