#!/usr/bin/env perl

use Test::Most;
use Plack::Test;
use Test::HTTP::Response;
use JSON::MaybeXS;
use Devel::Dwarn;

use lib "t/lib";
use TestDS;
use WebAPI::DBIC::WebApp;

use Test::Roo;
with 'TestRole::Schema';


after setup => sub {
    my ($self) = @_;
    $self->load_fixtures(qw(basic));
};


local $SIG{__DIE__} = \&Carp::confess;

test "===== Paging =====" => sub {
    my ($self) = @_;

    my $app = WebAPI::DBIC::WebApp->new({
        schema => $self->schema,
    })->to_psgi_app;


    my %artists;

    test_psgi $app, sub {
        my $data = dsresp_ok(shift->(dsreq( GET => "/artist" )));
        %artists = map { $_->{artistid} => $_ } @$data;
    };

    test_psgi $app, sub {
        dsresp_ok(shift->(dsreq( GET => "/artist?me.nonesuch=42" )), 400);
    };

    for my $id (2,3) {
        test_psgi $app, sub {
            my $data = dsresp_ok(shift->(dsreq( GET => "/artist?me.artistid=$id" )));
            eq_or_diff $data->[0], $artists{$id}, 'record matches';
        };
    }
    ;

    subtest "search by json array" => sub {
        test_psgi $app, sub {
            my $data = dsresp_ok(shift->(dsreq( GET => url_query("/artist", "me.artistid~json"=>[1,3]) )));
            eq_or_diff $data->[0], $artists{1}, 'record matches';
            eq_or_diff $data->[1], $artists{3}, 'record matches';
        };
    };

    subtest "search by json hash" => sub {
        test_psgi $app, sub {
            my $data = dsresp_ok(shift->(dsreq( GET => url_query("/artist", "me.artistid~json"=>{ "<=", 2 }) )));
            eq_or_diff $data->[0], $artists{1}, 'record matches';
            eq_or_diff $data->[1], $artists{2}, 'record matches';
        };
    };
};


run_me();
done_testing();
