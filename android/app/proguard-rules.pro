# TensorFlow Lite GPU delegate — referenced by the vision-model benchmark
# harness (see lib/services/benchmark/model_benchmark_service.dart), NOT by
# the voice onboarding implementation or any production code path.
#
# tflite_flutter's Android plugin code includes optional GPU-delegate
# support (org.tensorflow.lite.gpu.GpuDelegateFactory$Options and
# $GpuBackend) unconditionally, regardless of whether the app actually
# constructs a GpuDelegateV2 at runtime. Those two classes live in a
# separate companion artifact (org.tensorflow:tensorflow-lite-gpu-api)
# that this project does not declare — only the base
# org.tensorflow:tensorflow-lite-gpu artifact is present (see
# android/app/build.gradle.kts). R8's whole-program shrinking flags the
# unresolved reference as a build error during release minification.
#
# This does NOT disable GPU delegate benchmarking, and does not affect
# whether it actually works on a given device: if the real native GPU
# delegate library is present at runtime, GpuDelegateV2() still succeeds
# normally. It only tells R8 not to fail the RELEASE BUILD over a
# build-time-only reference — ModelBenchmarkService already treats a
# missing/failing GPU delegate as a graceful, expected benchmark result
# (a "device/model doesn't support this delegate" row), never a crash,
# for exactly this reason: NNAPI/GPU acceleration is not guaranteed to be
# available or beneficial on every device, which is the whole point of
# measuring it empirically per Stage 0's benchmark framework.
-dontwarn org.tensorflow.lite.gpu.**
