package WebAPI::DBIC::Resource::Role::DBIC_JSONAPI;

=head1 NAME

WebAPI::DBIC::Resource::Role::DBIC_JSONAPI - a role with core JSON API methods for DBIx::Class resources

=cut

use Carp qw(croak confess);
use Devel::Dwarn;
use JSON::MaybeXS qw(JSON);

use Moo::Role;


requires 'get_url_for_item_relationship';
requires 'render_item_as_plain_hash';
requires 'path_for_item';
requires 'add_params_to_url';
requires 'prefetch';


sub jsonapi_type { # XXX this is a hack - needs more thought
    my ($self) = @_;

    my $result_source = $self->set->result_source;

    my $url = $self->uri_for(result_class => $result_source->result_class)
        or confess sprintf("panic: no route found to %s result_class %s",
            $self, $result_source->result_class
        );
    my $path = URI->new($url,'http')->path;
    $path =~ s!^/([^/]+)!$1! or die "panic: Can't get jsonapi_type from $path";

    return $path;
}


sub render_jsonapi_response { # return top-level document hashref
    my ($self, $set) = @_;

    my $set_key  = ($self->param('distinct')) ? 'data' : $self->jsonapi_type;

    my %links;
    for my $relname ($set->result_class->relationships) {

        my $rel_info = $set->result_class->relationship_info($relname);

        my $link_url_templated = $self->get_url_template_for_set_relationship($set, $relname);
        next if not defined $link_url_templated;

        # XXX a hack to keep the template urls readable!
        $link_url_templated =~ s/%7B/{/g;
        $link_url_templated =~ s/%7D/}/g;

        my $link_name = "$set_key.$relname";
        $links{$link_name} = "$link_url_templated"; # XXX stringify the URL object
    }

    for my $prefetch (@{$self->prefetch||[]}) {
        while (my ($rel, $sub_rel) = each %{$prefetch}){
            next if $rel eq 'self';
            #my $subitem = $item->$rel();
        }
    }

    my $set_data = $self->render_set_as_array_of_jsonapi_resource_objects($set, undef);

    my ($linked, $links) = $self->_render_linked_jsonapi($set);

    my $top_doc = { # http://jsonapi.org/format/#document-structure-top-level
        $set_key => $set_data,
        # linked
    };
    $top_doc->{links} = \%links if keys %links;

    my $total_items;
    if (($self->param('with')||'') =~ /count/) { # XXX
        $total_items = $set->pager->total_entries;
        $top_doc->{meta}{count} = $total_items; # XXX detail not in spec
    }

    return $top_doc;
}



sub render_item_as_jsonapi_hash {
    my ($self, $item) = @_;

    my $data = $self->render_item_as_plain_hash($item);

    $data->{type} = $self->jsonapi_type;
    $data->{href} = $self->path_for_item($item);

    $self->_render_prefetch_jsonapi($item, $data, $_) for @{$self->prefetch||[]};

    # add links for relationships

    return $data;
}


sub _render_prefetch_jsonapi {
    my ($self, $item, $data, $prefetch) = @_;

    while (my ($rel, $sub_rel) = each %{$prefetch}){
        next if $rel eq 'self';

        my $subitem = $item->$rel();

        if (not defined $subitem) {
            $data->{_embedded}{$rel} = undef; # show an explicit null from a prefetch
        }
        elsif ($subitem->isa('DBIx::Class::ResultSet')) { # one-to-many rel
            my $rel_set_resource = $self->web_machine_resource(
                set         => $subitem,
                item        => undef,
                prefetch    => ref $sub_rel eq 'ARRAY' ? $sub_rel : [$sub_rel],
            );
            $data->{_embedded}{$rel} = $rel_set_resource->render_set_as_array_of_jsonapi_resource_objects($subitem, undef);
        }
        else {
            $data->{_embedded}{$rel} = $self->render_item_as_plain_hash($subitem);
        }
    }
}

sub render_set_as_array_of_jsonapi_resource_objects {
    my ($self, $set, $render_method, $edit_hook) = @_;
    $render_method ||= 'render_item_as_jsonapi_hash';

    my @jsonapi_objs;
    while (my $row = $set->next) {
        push @jsonapi_objs, $self->$render_method($row);
        $edit_hook->($jsonapi_objs[-1]) if $edit_hook;
    }

    return \@jsonapi_objs;
}



sub _render_linked_jsonapi {
    my ($self, $item, $data, $prefetch) = @_;

    while (my ($rel, $sub_rel) = each %{$prefetch}){
        next if $rel eq 'self';

        my $subitem = $item->$rel();

        # XXX perhaps render_item_as_jsonapi_hash but requires cloned WM, eg without prefetch
        # If we ever do render_item_as_jsonapi_hash then we need to ensure that "a link
        # inside an embedded resource implicitly relates to that embedded
        # resource and not the parent."
        # See http://blog.stateless.co/post/13296666138/json-linking-with-jsonapi
        if (not defined $subitem) {
            $data->{_embedded}{$rel} = undef; # show an explicit null from a prefetch
        }
        elsif ($subitem->isa('DBIx::Class::ResultSet')) { # one-to-many rel
            my $rel_set_resource = $self->web_machine_resource(
                set         => $subitem,
                item        => undef,
                prefetch    => ref $sub_rel eq 'ARRAY' ? $sub_rel : [$sub_rel],
            );
            $data->{_embedded}{$rel} = $rel_set_resource->render_set_as_array_of_jsonapi_resource_objects($subitem, undef);
        }
        else {
            $data->{_embedded}{$rel} = $self->render_item_as_plain_hash($subitem);
        }
    }
}

sub _jsonapi_page_links {
    my ($self, $set, $base, $page_items, $total_items) = @_;

    # XXX we ought to allow at least the self link when not pages
    return () unless $set->is_paged;

    # XXX we break encapsulation here, sadly, because calling
    # $set->pager->current_page triggers a "select count(*)".
    # XXX When we're using a later version of DBIx::Class we can use this:
    # https://metacpan.org/source/RIBASUSHI/DBIx-Class-0.08208/lib/DBIx/Class/ResultSet/Pager.pm
    # and do something like $rs->pager->total_entries(sub { 99999999 })
    my $rows = $set->{attrs}{rows} or confess "panic: rows not set";
    my $page = $set->{attrs}{page} or confess "panic: page not set";

    # XXX this self link this should probably be subtractive, ie include all
    # params by default except any known to cause problems
    my $url = $self->add_params_to_url($base, { distinct=>1, with=>1, me=>1 }, { rows => $rows });
    my $linkurl = $url->as_string;
    $linkurl .= "&page="; # hack to optimize appending page 5 times below

    my @link_kvs;
    push @link_kvs, self  => {
        href => $linkurl.($page),
        title => $set->result_class,
    };
    push @link_kvs, next  => { href => $linkurl.($page+1) }
        if $page_items == $rows;
    push @link_kvs, prev  => { href => $linkurl.($page-1) }
        if $page > 1;
    push @link_kvs, first => { href => $linkurl.1 }
        if $page > 1;
    push @link_kvs, last  => { href => $linkurl.$set->pager->last_page }
        if $total_items and $page != $set->pager->last_page;

    return @link_kvs;
}


1;
