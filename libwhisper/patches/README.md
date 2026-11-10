# Local whisper.cpp patches

`ggml-metal-rsets-idle-heartbeat.patch` makes ggml's Metal residency-set heartbeat block on a semaphore once its keep-alive expires, instead of waking every 5 ms for the life of the process; keep-alive and free wake it.
It is local because upstream has no fix as of whisper.cpp `bd9e1a12` (2026-11-09); the 5 ms poll is still there.
`libwhisper/CMakeLists.txt` applies it with zero fuzz (`patch -F 0`) to a copy in the CMake build tree, so the submodule stays pristine.
After a submodule bump, configuration fails loudly if any hunk or context line no longer matches; refresh it against the new commit.
