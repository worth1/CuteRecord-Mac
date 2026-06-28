// Placeholder for c-api.h
// This is a minimal placeholder to allow compilation
// The actual SherpaOnnx library files need to be obtained from the official repository

#ifndef SHERPA_ONNX_C_API_H
#define SHERPA_ONNX_C_API_H

#ifdef __cplusplus
extern "C" {
#endif

// Minimal placeholder structures and functions
typedef void* SherpaOnnxRecognizer;
typedef struct SherpaOnnxOnlineRecognizerConfig SherpaOnnxOnlineRecognizerConfig;

// Placeholder function declarations
SherpaOnnxRecognizer* CreateSherpaOnnxRecognizer(const SherpaOnnxOnlineRecognizerConfig* config);
void DestroySherpaOnnxRecognizer(SherpaOnnxRecognizer* recognizer);

#ifdef __cplusplus
}
#endif

#endif // SHERPA_ONNX_C_API_H