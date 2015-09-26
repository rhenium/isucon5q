package ExtUtils::Config;
{
  $ExtUtils::Config::VERSION = '0.007';
}

use strict;
use warnings;
use Config;
use Data::Dumper ();

sub new {
	my ($pack, $args) = @_;
	return bless {
		values => ($args ? { %$args } : {}),
	}, $pack;
}

sub clone {
	my $self = shift;
	return __PACKAGE__->new($self->{values});
}

sub get {
	my ($self, $key) = @_;
	return exists $self->{values}{$key} ? $self->{values}{$key} : $Config{$key};
}

sub set {
	my ($self, $key, $val) = @_;
	$self->{values}{$key} = $val;
	delete $self->{serialized};
	return;
}

sub clear {
	my ($self, $key) = @_;
	delete $self->{values}{$key};
	delete $self->{serialized};
	return;
}

sub exists {
	my ($self, $key) = @_;
	return exists $self->{values}{$key} || exists $Config{$key};
}

sub values_set {
	my $self = shift;
	return { %{$self->{values}} };
}

sub all_config {
	my $self = shift;
	return { %Config, %{ $self->{values}} };
}

sub serialize {
	my $self = shift;
	return $self->{serialized} ||= Data::Dumper->new([$self->values_set])->Terse(1)->Sortkeys(1)->Dump;
}

1;



=pod

=head1 NAME

ExtUtils::Config - A wrapper for perl's configuration

=head1 VERSION

version 0.007

=head1 SYNOPSIS

 my $config = ExtUtils::Config->new();
 $config->set('installsitelib', "$ENV{HOME}/lib");

=head1 DESCRIPTION

ExtUtils::Config is an abstraction around the %Config hash.

=head1 METHODS

=head2 new(\%config)

Create a new ExtUtils::Config object. The values in C<\%config> are used to initialize the object.

=head2 get($key)

Get the value of C<$key>. If not overriden it will return the value in %Config.

=head2 exists($key)

Tests for the existence of $key.

=head2 set($key, $value)

Set/override the value of C<$key> to C<$value>.

=head2 clear($key)

Reset the value of C<$key> to its original value.

=head2 values_set()

Get a hashref of all overridden values.

=head2 all_config()

Get a hashref of the complete configuration, including overrides.

=head2 clone()

Clone the current configuration object.

=head2 serialize()

This method serializes the object to some kind of string.

=head1 AUTHORS

=over 4

=item *

Ken Williams <kwilliams@cpan.org>

=item *

Leon Timmermans <leont@cpan.org>

=back

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2006 by Ken Williams, Leon Timmermans.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


__END__

# ABSTRACT: A wrapper for perl's configuration

