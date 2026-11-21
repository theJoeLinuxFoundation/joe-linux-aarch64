prepare() {
    # Publish the same platform setting in ICU's installed headers. joe's
    # default time zone comes from /etc/localtime, not Android properties.
    sed -i '/^#elif defined(__ANDROID__)$/,/^#   include <android\/api-level.h>$/d' \
        source/common/unicode/platform.h
}

build() {
    cd source
    ./configure --prefix=/usr --disable-tests --disable-samples
    make
}

package() {
    cd source
    make DESTDIR="$DESTDIR" install
}
