# Match rpmbuild's trace of the two-kernel %build loop. Only attribute a
# failure when rpmbuild confirms that %build exited while the helper was active.
/^Executing\(/ {
    in_build = /^Executing\(%build\):/
    kernel = ""
}
in_build && /^\+ \.\/build-offline\.sh / {
    kernel = $4
    sub("^/usr/src/kernels/", "", kernel)
    path = $3
    sub("^.*/", "", path)
    if (NF != 4 || $4 != "/usr/src/kernels/" kernel || path != "build-" kernel) kernel = ""
    phase = "build"
}
/^Built \// { kernel = "" }
/^Unexpected module vermagic:/ { phase = "module-verification" }
in_build && kernel != "" && /Bad exit status from .* \(%build([[:space:]][^)]*)?\)/ {
    print kernel, phase
    exit
}
