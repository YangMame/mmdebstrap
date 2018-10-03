#!/bin/sh

set -eu

mirrordir="./mirror"
cachedir="./cache"

# by default, use the mmdebstrap executable in the current directory but allow
# overwriting the location
: "${mmdebstrap:=./mmdebstrap}"

# by default a cache of debootstrap results is maintained
: "${docache:=true}"

mirror="http://deb.debian.org/debian"
rootdir=$(mktemp --directory)
nativearch=$(dpkg --print-architecture)
components=main

abort=no
for dist in stable testing unstable; do
	if [ -e debian-$dist-mm ]; then
		echo "debian-$dist-mm exists"
		abort=yes
	fi
	if [ -e debian-$dist-debootstrap ]; then
		echo "debian-$dist-debootstrap exists"
		abort=yes
	fi
done
if [ $abort = yes ]; then
	exit 1
fi

./make_mirror.sh

cd mirror
python3 -m http.server 8000 2>/dev/null & pid=$!
cd -

# wait for the server to start
sleep 1

if ! kill -0 $pid; then
	echo "failed to start http server"
	exit 1
fi

trap 'kill $pid' INT QUIT TERM EXIT

echo "running http server with pid $pid"

# choose the timestamp of the unstable Release file, so that we get
# reproducible results for the same mirror timestamp
export SOURCE_DATE_EPOCH=$(date --date="$(grep-dctrl -s Date -n '' mirror/dists/unstable/Release)" +%s)

mkdir -p "$cachedir"

for dist in stable testing unstable; do
	> timings
	> sizes
	for variant in minbase buildd -; do
		# skip because of different userids for apt/systemd
		if [ "$dist" = 'stable' -a "$variant" = '-' ]; then
			continue
		fi
		echo =========================================================
		echo                   $dist $variant
		echo =========================================================

		echo running $mmdebstrap --variant=$variant --mode=unshare $dist debian-$dist-mm.tar "http://localhost:8000"
		/usr/bin/time --output=timings --append --format=%e $mmdebstrap --variant=$variant --mode=unshare $dist debian-$dist-mm.tar "http://localhost:8000"

		stat --format=%s debian-$dist-mm.tar >> sizes
		mkdir ./debian-$dist-mm
		sudo tar -C ./debian-$dist-mm -xf ./debian-$dist-mm.tar

		if [ "$docache" != "true" ] || [ ! -e "$cachedir/debian-$dist-$variant.tar" ]; then
			echo running debootstrap --merged-usr --variant=$variant $dist ./debian-$dist-debootstrap "http://localhost:8000/"
			/usr/bin/time --output=timings --append --format=%e sudo debootstrap --merged-usr --variant=$variant $dist ./debian-$dist-debootstrap "http://localhost:8000/"
			sudo tar --sort=name --mtime=@$SOURCE_DATE_EPOCH --clamp-mtime --numeric-owner --one-file-system -C ./debian-$dist-debootstrap -c . > "$cachedir/debian-$dist-$variant.tar"
			sudo rm -r ./debian-$dist-debootstrap
		else
			echo cached >> timings
		fi

		stat --format=%s "$cachedir/debian-$dist-$variant.tar" >> sizes
		mkdir ./debian-$dist-debootstrap
		sudo tar -C ./debian-$dist-debootstrap -xf "$cachedir/debian-$dist-$variant.tar"

		# diff cannot compare device nodes, so we use tar to do that for us and then
		# delete the directory
		tar -C ./debian-$dist-debootstrap -cf dev1.tar ./dev
		tar -C ./debian-$dist-mm -cf dev2.tar ./dev
		cmp dev1.tar dev2.tar
		rm dev1.tar dev2.tar
		sudo rm -r ./debian-$dist-debootstrap/dev ./debian-$dist-mm/dev

		# remove downloaded deb packages
		sudo rm debian-$dist-debootstrap/var/cache/apt/archives/*.deb
		# remove aux-cache
		sudo rm debian-$dist-debootstrap/var/cache/ldconfig/aux-cache
		# remove logs
		sudo rm debian-$dist-debootstrap/var/log/dpkg.log \
			debian-$dist-debootstrap/var/log/bootstrap.log \
			debian-$dist-mm/var/log/apt/eipp.log.xz \
			debian-$dist-debootstrap/var/log/alternatives.log
		# remove *-old files
		sudo rm debian-$dist-debootstrap/var/cache/debconf/config.dat-old \
			debian-$dist-mm/var/cache/debconf/config.dat-old
		sudo rm debian-$dist-debootstrap/var/cache/debconf/templates.dat-old \
			debian-$dist-mm/var/cache/debconf/templates.dat-old
		sudo rm debian-$dist-debootstrap/var/lib/dpkg/status-old \
			debian-$dist-mm/var/lib/dpkg/status-old
		# remove dpkg files
		sudo rm debian-$dist-debootstrap/var/lib/dpkg/available \
			debian-$dist-debootstrap/var/lib/dpkg/cmethopt
		# since we installed packages directly from the .deb files, Priorities differ
		# this we first check for equality and then remove the files
		sudo chroot debian-$dist-debootstrap dpkg --list > dpkg1
		sudo chroot debian-$dist-mm dpkg --list > dpkg2
		diff -u dpkg1 dpkg2
		rm dpkg1 dpkg2
		grep -v '^Priority: ' debian-$dist-debootstrap/var/lib/dpkg/status > status1
		grep -v '^Priority: ' debian-$dist-mm/var/lib/dpkg/status > status2
		diff -u status1 status2
		rm status1 status2
		sudo rm debian-$dist-debootstrap/var/lib/dpkg/status debian-$dist-mm/var/lib/dpkg/status
		# this file is only created by apt 1.6 or newer
		if [ "$dist" != "stable" ]; then
			sudo rmdir debian-$dist-mm/var/lib/apt/lists/auxfiles
		fi
		# debootstrap exposes the hosts's kernel version
		sudo rm debian-$dist-debootstrap/etc/apt/apt.conf.d/01autoremove-kernels \
			debian-$dist-mm/etc/apt/apt.conf.d/01autoremove-kernels
		# who creates /run/mount?
		sudo rm -f debian-$dist-debootstrap/run/mount/utab
		sudo rmdir debian-$dist-debootstrap/run/mount
		# debootstrap doesn't clean apt
		sudo rm debian-$dist-debootstrap/var/lib/apt/lists/localhost:8000_dists_${dist}_main_binary-amd64_Packages \
			debian-$dist-debootstrap/var/lib/apt/lists/localhost:8000_dists_${dist}_Release \
			debian-$dist-debootstrap/var/lib/apt/lists/localhost:8000_dists_${dist}_Release.gpg

		if [ "$variant" = "-" ]; then
			sudo rm debian-$dist-debootstrap/etc/machine-id
			sudo rm debian-$dist-mm/etc/machine-id
			sudo rm debian-$dist-debootstrap/var/lib/systemd/catalog/database
			sudo rm debian-$dist-mm/var/lib/systemd/catalog/database
		fi
		sudo rm debian-$dist-debootstrap/var/lib/dpkg/lock
		# introduced in dpkg 1.19.1
		if [ "$dist" = "unstable" ]; then
			sudo rm debian-$dist-debootstrap/var/lib/dpkg/lock-frontend
		fi

		# check if the file content differs
		sudo diff --no-dereference --brief --recursive debian-$dist-debootstrap debian-$dist-mm

		sudo rm -rf ./debian-$dist-debootstrap ./debian-$dist-mm \
			./debian-$dist-mm.tar
		if [ "$docache" != "true" ]; then
			rm "$cachedir/debian-$dist-$variant.tar"
		fi
	done

	eval $(awk '{print "var"NR"="$1}' timings)

	echo
	echo "timings"
	echo "======="
	echo
	echo "variant | mmdebstrap | debootstrap"
	echo "--------+------------+------------"
	echo "minbase | $var1      | $var2"
	echo "buildd  | $var3      | $var4"
	if [ "$dist" != 'stable' ]; then
		echo "-       | $var5      | $var6"
	fi

	eval $(awk '{print "var"NR"="$1}' sizes)

	echo
	echo "sizes"
	echo "======="
	echo
	echo "variant | mmdebstrap | debootstrap"
	echo "--------+------------+------------"
	echo "minbase | $var1  | $var2"
	echo "buildd  | $var3  | $var4"
	if [ "$dist" != 'stable' ]; then
		echo "-       | $var5  | $var6"
	fi

	rm timings sizes
done

kill $pid

wait $pid || true

trap - INT QUIT TERM EXIT

