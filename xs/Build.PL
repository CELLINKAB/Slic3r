#!/usr/bin/perl -w

use strict;
use warnings;

use Config;
use Devel::CheckLib;
use ExtUtils::CppGuess;
use Module::Build::WithXSpp;

my $cpp_guess = ExtUtils::CppGuess->new;
my $mswin = $^O eq 'MSWin32';
my $linux = $^O eq 'linux';

# prevent an annoying concatenation warning by Devel::CheckLib
$ENV{LD_RUN_PATH} //= "";

# _GLIBCXX_USE_C99 : to get the long long type for g++
# HAS_BOOL         : stops Perl/lib/CORE/handy.h from doing "#  define bool char" for MSVC
# NOGDI            : prevents inclusion of wingdi.h which defines functions Polygon() and Polyline() in global namespace
# BOOST_ASIO_DISABLE_KQUEUE : prevents a Boost ASIO bug on OS X: https://svn.boost.org/trac/boost/ticket/5339
my @cflags = qw(-D_GLIBCXX_USE_C99 -DHAS_BOOL -DNOGDI -DSLIC3RXS -DBOOST_ASIO_DISABLE_KQUEUE -Dexprtk_disable_rtl_io_file -Dexprtk_disable_return_statement -Dexprtk_disable_rtl_vecops -Dexprtk_disable_string_capabilities -Dexprtk_disable_enhanced_features);
push @cflags, "-DSLIC3R_BUILD_COMMIT=$ENV{SLIC3R_GIT_VERSION}" if defined $ENV{SLIC3R_GIT_VERSION};

if ($cpp_guess->is_gcc)	{
	# GCC is pedantic with c++11 std, so undefine strict ansi to get M_PI back
	push @cflags, qw(-U__STRICT_ANSI__);
}

# std=c++11 Enforce usage of C++11 (required now). Minimum compiler supported: gcc 4.9, clang 3.3, MSVC 14.0
push @cflags, qw(-std=c++11);

my @ldflags = ();

if ($linux && (defined $ENV{SLIC3R_STATIC} && $ENV{SLIC3R_STATIC})) {
    push @ldflags, qw(-static-libgcc -static-libstdc++);
    if ($ENV{TRAVIS}) {
        # On the build server, link to the actual static libraries to make sure we get them in the list.
    	push @ldflags, qw(/usr/lib/gcc/x86_64-linux-gnu/4.9/libstdc++.a /usr/lib/gcc/x86_64-linux-gnu/4.9/libgcc.a);
    }
    # ExtUtils::CppGuess has a hard-coded -lstdc++, so we filter it out
    {
        no strict 'refs';
        no warnings 'redefine';
        my $func = "ExtUtils::CppGuess::_get_lflags";
        my $orig = *$func{CODE};
        *{$func} = sub {
            my $lflags = $orig->(@_);
            $lflags =~ s/\s*-lstdc\+\+//;
            return $lflags;
        };
    }
}

if ($^O eq 'darwin') {
    push @cflags, qw(-stdlib=libc++);
    push @ldflags, qw(-framework IOKit -framework CoreFoundation -lc++);
    
    # Due to a bug/misconfiguration/stupidity, boost 1.52 and libc++ don't like each
    # other much: a compilation error "Constexpr function never produces a constant
    # expression" pops up when trying to compile anything that uses
    # boost/chrono/duration.hpp (namely boost/thread for us). This is a workaround
    # that prevents this from happening, not needed with newer Boost versions.
    # See here for more details: https://svn.boost.org/trac/boost/ticket/7671
    push @cflags, qw(-DBOOST_THREAD_DONT_USE_CHRONO -DBOOST_NO_CXX11_RVALUE_REFERENCES -DBOOST_THREAD_USES_MOVE);
    
    # ExtUtils::CppGuess has a hard-coded -lstdc++, so we filter it out
    {
        no strict 'refs';
        no warnings 'redefine';
        my $func = "ExtUtils::CppGuess::_get_lflags";
        my $orig = *$func{CODE};
        *{$func} = sub {
            my $lflags = $orig->(@_);
            $lflags =~ s/\s*-lstdc\+\+//;
            return $lflags;
        };
    }
}
if ($mswin) {
    push @cflags, qw(-DNOMINMAX);
}

my @INC  = qw(-Isrc/libslic3r);
my @LIBS = $cpp_guess->is_msvc ? qw(-LIBPATH:src/libslic3r) : qw(-Lsrc/libslic3r);

push @cflags, '-DBOOST_LIBS';
my @boost_libraries = qw(system thread filesystem);  # we need these
push @LIBS, map "-lboost_${_}", @boost_libraries;

if ($ENV{SLIC3R_DEBUG}) {
    # only on newer GCCs: -ftemplate-backtrace-limit=0
    push @cflags, '-DSLIC3R_DEBUG';
    push @cflags, $cpp_guess->is_msvc ? '-Gd' : '-g';
} else {
    # Disable asserts in the release builds.
    push @cflags, '-DNDEBUG', '-O';
}
if ($cpp_guess->is_gcc) {
    # our templated XS bindings cause undefined-var-template warnings
    push @cflags, qw(-Wno-undefined-var-template);
}

my $build = Module::Build::WithXSpp->new(
    module_name     => 'Slic3r::XS',
    dist_abstract   => 'XS code for Slic3r',
    build_requires => {qw(
        ExtUtils::ParseXS           3.35
        ExtUtils::Typemaps          1.00
        ExtUtils::Typemaps::Default 1.05
        ExtUtils::XSpp              0.18
        Module::Build               0.3601
        Test::More                  0
    )},
    configure_requires => {qw(
        ExtUtils::CppGuess          0.07
        Module::Build               0.38
        Module::Build::WithXSpp     0.13
    )},
    extra_compiler_flags => [ @INC, @cflags ],
    extra_linker_flags => [ @LIBS, @ldflags ],
    
    # Provides extra C typemaps that are auto-merged
    extra_typemap_modules => {
        'ExtUtils::Typemaps::Basic' => '1.05',
    },
    
    # for MSVC builds
    early_includes => [qw(
        cstring
        cstdlib
        ostream
        sstream
        libslic3r/GCodeSender.hpp
    )]
);

$build->create_build_script;

__END__
