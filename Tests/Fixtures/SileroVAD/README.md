# Offline VAD test fixture

This is a test-only copy of Silero VAD v6.2.1 from
https://huggingface.co/FluidInference/silero-vad-coreml/tree/b419383c55c110e2c9271fa6ee0ea83d03c70d96.
The five export files total 1,063,425 bytes. The receipt contains the reviewed
manifest, including each immutable digest and byte count.

CI explicitly points its offline verification gate at this directory. The same
production verifier checks every file and refuses missing, modified or extra
files inside the installation. No installer or model download runs in CI.
This directory is excluded from SwiftPM targets and never packaged in the app.
Application startup and recording still require an explicit model download.

The model is MIT licensed. The upstream license is retained in LICENSE:
https://github.com/snakers4/silero-vad/blob/master/LICENSE.
