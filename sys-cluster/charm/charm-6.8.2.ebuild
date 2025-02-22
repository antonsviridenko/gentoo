# Copyright 1999-2021 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=5

FORTRAN_STANDARD="90"

inherit eutils flag-o-matic fortran-2 multilib multiprocessing toolchain-funcs

DESCRIPTION="Message-passing parallel language and runtime system"
HOMEPAGE="http://charm.cs.uiuc.edu/"
SRC_URI="http://charm.cs.uiuc.edu/distrib/${P}.tar.gz"

LICENSE="charm"
SLOT="0"
KEYWORDS="~amd64 ~x86"
IUSE="charmdebug charmtracing charmproduction cmkopt examples mlogft mpi ampi numa smp static-libs syncft tcp"

RDEPEND="mpi? ( virtual/mpi )"
DEPEND="
	${RDEPEND}
	net-libs/libtirpc
	virtual/pkgconfig
"

REQUIRED_USE="
	cmkopt? ( !charmdebug !charmtracing )
	charmproduction? ( !charmdebug !charmtracing )"

S="${WORKDIR}/${PN}-v${PV}"

get_opts() {
	local CHARM_OPTS

	# TCP instead of default UDP for socket comunication
	# protocol
	CHARM_OPTS+="$(usex tcp ' tcp' '')"

	# enable direct SMP support using shared memory
	CHARM_OPTS+="$(usex smp ' smp' '')"

	CHARM_OPTS+="$(usex mlogft ' mlogft' '')"
	CHARM_OPTS+="$(usex syncft ' syncft' '')"

	# Build shared libraries by default.
	CHARM_OPTS+=" --build-shared"

	if use charmproduction; then
		CHARM_OPTS+=" --with-production"
	else
		if use charmdebug; then
			CHARM_OPTS+=" --enable-charmdebug"
		fi

		if use charmtracing; then
			CHARM_OPTS+=" --enable-tracing --enable-tracing-commthread"
		fi
	fi

	CHARM_OPTS+="$(usex numa ' --with-numa' '')"
	echo $CHARM_OPTS
}

src_prepare() {
	append-cppflags $($(tc-getPKG_CONFIG) --cflags libtirpc)

	sed \
		-e "/CMK_CF77/s:[fg]77:$(usex mpi "mpif90" "$(tc-getF77)") ${FCFLAGS}:g" \
		-e "/CMK_CF90/s:f95:$(usex mpi "mpif90" "$(tc-getFC)") ${FCFLAGS}:g" \
		-e "/CMK_CF90/s:\`which f90.*$::g" \
		-e "/CMK_CXX/s:g++:$(usex mpi "mpic++" "$(tc-getCXX)") ${CPPFLAGS} ${CXXFLAGS}:g" \
		-e "/CMK_CC/s:gcc:$(usex mpi "mpicc" "$(tc-getCC)") ${CPPFLAGS} ${CFLAGS}:g" \
		-e '/CMK_F90_MODINC/s:-p:-I:g' \
		-e "/CMK_LD/s:\"$: ${LDFLAGS} \":g" \
		-i src/arch/$(usex mpi "mpi" "net")*-linux*/*sh || die
	sed \
		-e "/CMK_CF90/s:gfortran:$(usex mpi "mpif90" "$(tc-getFC)") ${FCFLAGS}:g" \
		-e "/F90DIR/s:gfortran:$(usex mpi "mpif90" "$(tc-getFC)") ${FCFLAGS}:g" \
		-e "/f95target/s:gfortran:$(usex mpi "mpif90" "$(tc-getFC)") ${FCFLAGS}:g" \
		-e "/f95version/s:gfortran:$(usex mpi "mpif90" "$(tc-getFC)") ${FCFLAGS}:g" \
		-i src/arch/common/*.sh || die

	sed \
		-e "s:-o conv-cpm:${LDFLAGS} &:g" \
		-e "s:-o charmxi:${LDFLAGS} &:g" \
		-e "s:-o charmrun-silent:${LDFLAGS} &:g" \
		-e "s:-o charmrun-notify:${LDFLAGS} &:g" \
		-e "s:-o charmrun:${LDFLAGS} &:g" \
		-e "s:-o charmd_faceless:${LDFLAGS} &:g" \
		-e "s:-o charmd:${LDFLAGS} &:g" \
		-e "/^CHARMC/s:$: ${CPPFLAGS} ${CFLAGS}:g" \
		-i \
		src/scripts/Makefile \
		src/util/charmrun-src/Makefile || die

	# CMK optimization
	use cmkopt && append-cppflags -DCMK_OPTIMIZE=1

	# Fix QA notice. Filed report with upstream.
	append-cflags -DALLOCA_H
}

src_compile() {
	local build_version="$(usex mpi "mpi" "net")-linux$(usex amd64 "-amd64" '')"
	local build_options="$(get_opts)"
	#build only accepts -j from MAKEOPTS
	local build_commandline="${build_version} ${build_options} -j$(makeopts_jobs)"

	# Build charmm++ first.
	einfo "running ./build charm++ ${build_commandline}"
	./build charm++ ${build_commandline} || die "Failed to build charm++"

	if use ampi; then
		einfo "running ./build AMPI ${build_commandline}"
		./build AMPI ${build_commandline} || die "Failed to build charm++"
	fi
}

src_test() {
	make -C tests/charm++ test TESTOPTS="++local" || die
}

src_install() {
	# Make charmc play well with gentoo before we move it into /usr/bin. This
	# patch cannot be applied during src_prepare() because the charmc wrapper
	# is used during building.
	epatch "${FILESDIR}/charm-6.5.1-charmc-gentoo.patch"

	sed -e "s|gentoo-include|${P}|" \
		-e "s|gentoo-libdir|$(get_libdir)|g" \
		-e "s|VERSION|${P}/VERSION|" \
		-i ./src/scripts/charmc || die "failed patching charmc script"

	# In the following, some of the files are symlinks to ../tmp which we need
	# to dereference first (see bug 432834).

	local i

	# Install binaries.
	for i in bin/*; do
		if [[ -L ${i} ]]; then
			i=$(readlink -e "${i}") || die
		fi
		dobin "${i}"
	done

	# Install headers.
	insinto /usr/include/${P}
	for i in include/*; do
		if [[ -L ${i} ]]; then
			i=$(readlink -e "${i}") || die
		fi
		doins "${i}"
	done

	# Install libs incl. charm objects
	for i in lib*/*.{so,a}; do
		[[ ${i} = *.a ]] && use !static-libs && continue
		if [[ -L ${i} ]]; then
			i=$(readlink -e "${i}") || die
		fi
		[[ -s $i ]] || continue
		[[ ${i} = *.so ]] && dolib.so "${i}" || dolib "${i}"
	done

	# Basic docs.
	dodoc CHANGES README

	# Install examples.
	if use examples; then
		find examples/ -name 'Makefile' | xargs sed \
			-r "s:(../)+bin/charmc:/usr/bin/charmc:" -i || \
			die "Failed to fix examples"
		find examples/ -name 'Makefile' | xargs sed \
			-r "s:./charmrun:./charmrun ++local:" -i || \
			die "Failed to fix examples"
		insinto /usr/share/doc/${PF}/examples
		doins -r examples/charm++/*
		docompress -x /usr/share/doc/${PF}/examples
	fi
}

pkg_postinst() {
	einfo "Please test your charm installation by copying the"
	einfo "content of /usr/share/doc/${PF}/examples to a"
	einfo "temporary location and run 'make test'."
}
