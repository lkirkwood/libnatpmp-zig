# libnatpmp-zig

These are Zig bindings, and a simple client, for the `libnatpmp` library written by Thomas Bernard [here](http://miniupnp.free.fr/libnatpmp.html).

It has no dependencies, other than `libnatpmp` and some system C libraries (see `include/libctypes.h`).
It's slightly easier to use than the C library because it provides a mechanism to await responses from the gateway, and it has all the niceties of Zig as well of course.

---
Generated with ❤️ by organic unintelligence 
