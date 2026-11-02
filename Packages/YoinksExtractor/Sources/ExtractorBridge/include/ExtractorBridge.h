#pragma once
#include <stdbool.h>
typedef struct IYOperation IYOperation;
typedef void (*IYEventCallback)(const char *json, void *context);
typedef char *(*IYMediaCallback)(IYOperation *operation, const char *json);
IYOperation *iy_operation_create(IYEventCallback callback, void *context, IYMediaCallback media);
void iy_operation_cancel(IYOperation *operation);
bool iy_operation_cancelled(IYOperation *operation);
void iy_operation_emit(IYOperation *operation, const char *json);
void iy_operation_free(IYOperation *operation);
char *iy_runtime_call(const char *home, const char *packages, const char *executable,
                      IYOperation *operation, const char *request);
void iy_free(void *pointer);
