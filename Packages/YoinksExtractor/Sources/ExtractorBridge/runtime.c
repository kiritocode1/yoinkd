#include "ExtractorBridge.h"
/* The iOS build uses Python.xcframework headers; host test builds use the interpreter's include path. */
#if __has_include(<Python/Python.h>)
#include <Python/Python.h>
#else
#include <Python.h>
#endif
#include <quickjs.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct IYOperation {
    atomic_bool cancelled;
    IYEventCallback callback;
    IYMediaCallback media;
    void *context;
};

IYOperation *iy_operation_create(IYEventCallback callback, void *context, IYMediaCallback media) {
    IYOperation *operation = calloc(1, sizeof(*operation));
    if (operation) {
        atomic_init(&operation->cancelled, false);
        operation->callback = callback;
        operation->context = context;
        operation->media = media;
    }
    return operation;
}
void iy_operation_cancel(IYOperation *operation) {
    if (operation) atomic_store(&operation->cancelled, true);
}
bool iy_operation_cancelled(IYOperation *operation) {
    return operation && atomic_load(&operation->cancelled);
}
void iy_operation_emit(IYOperation *operation, const char *json) {
    if (operation && operation->callback && !iy_operation_cancelled(operation))
        operation->callback(json, operation->context);
}
void iy_operation_free(IYOperation *operation) { free(operation); }
void iy_free(void *pointer) { free(pointer); }

static IYOperation *operation_from_object(PyObject *object) {
    if (object == Py_None) return NULL;
    return PyCapsule_GetPointer(object, "iYoinks.operation");
}
static PyObject *native_emit(PyObject *self, PyObject *args) {
    PyObject *token;
    const char *json;
    if (!PyArg_ParseTuple(args, "Os", &token, &json)) return NULL;
    IYOperation *operation = operation_from_object(token);
    if (PyErr_Occurred()) return NULL;
    iy_operation_emit(operation, json);
    Py_RETURN_NONE;
}
static PyObject *native_cancelled(PyObject *self, PyObject *token) {
    IYOperation *operation = operation_from_object(token);
    if (PyErr_Occurred()) return NULL;
    return PyBool_FromLong(iy_operation_cancelled(operation));
}
static PyObject *native_media(PyObject *self, PyObject *args) {
    PyObject *token;
    const char *json;
    if (!PyArg_ParseTuple(args, "Os", &token, &json)) return NULL;
    IYOperation *operation = operation_from_object(token);
    if (PyErr_Occurred()) return NULL;
    if (!operation || !operation->media) {
        PyErr_SetString(PyExc_RuntimeError, "The native media processor is unavailable.");
        return NULL;
    }
    char *result;
    Py_BEGIN_ALLOW_THREADS
    result = operation->media(operation, json);
    Py_END_ALLOW_THREADS
    if (!result) return PyErr_NoMemory();
    PyObject *output = PyUnicode_FromString(result);
    free(result);
    return output;
}

typedef struct {
    IYOperation *operation;
    double deadline;
    char *output;
    size_t size;
} IYJavaScript;
static double monotonic_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1000000000.0;
}
static int interrupt_javascript(JSRuntime *runtime, void *opaque) {
    IYJavaScript *state = opaque;
    return iy_operation_cancelled(state->operation) || monotonic_seconds() > state->deadline;
}
static JSValue javascript_print(JSContext *context, JSValueConst this_value, int count, JSValueConst *values) {
    IYJavaScript *state = JS_GetContextOpaque(context);
    for (int index = 0; index < count; index++) {
        const char *value = JS_ToCString(context, values[index]);
        if (!value) return JS_EXCEPTION;
        size_t length = strlen(value);
        if (state->size + length + 2 > 4 * 1024 * 1024) {
            JS_FreeCString(context, value);
            return JS_ThrowRangeError(context, "JavaScript output exceeded its limit");
        }
        char *buffer = realloc(state->output, state->size + length + 2);
        if (!buffer) { JS_FreeCString(context, value); return JS_ThrowOutOfMemory(context); }
        state->output = buffer;
        memcpy(buffer + state->size, value, length);
        state->size += length;
        buffer[state->size++] = index + 1 == count ? '\n' : ' ';
        buffer[state->size] = 0;
        JS_FreeCString(context, value);
    }
    return JS_UNDEFINED;
}
static PyObject *native_javascript(PyObject *self, PyObject *args) {
    PyObject *token;
    const char *source;
    if (!PyArg_ParseTuple(args, "Os", &token, &source)) return NULL;
    IYOperation *operation = operation_from_object(token);
    if (PyErr_Occurred()) return NULL;
    IYJavaScript state = { .operation = operation, .deadline = monotonic_seconds() + 25 };
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) return PyErr_NoMemory();
    JS_SetMemoryLimit(runtime, 160 * 1024 * 1024);
    JS_SetMaxStackSize(runtime, 256 * 1024);
    JS_SetInterruptHandler(runtime, interrupt_javascript, &state);
    JSContext *context = JS_NewContext(runtime);
    if (!context) { JS_FreeRuntime(runtime); return PyErr_NoMemory(); }
    JS_SetContextOpaque(context, &state);
    JSValue global = JS_GetGlobalObject(context);
    JSValue console = JS_NewObject(context);
    JS_SetPropertyStr(context, console, "log", JS_NewCFunction(context, javascript_print, "log", 1));
    JS_SetPropertyStr(context, global, "console", console);
    JS_SetPropertyStr(context, global, "print", JS_NewCFunction(context, javascript_print, "print", 1));
    JS_FreeValue(context, global);
    JSValue result;
    Py_BEGIN_ALLOW_THREADS
    result = JS_Eval(context, source, strlen(source), "youtube-challenge.js", JS_EVAL_TYPE_GLOBAL);
    Py_END_ALLOW_THREADS
    PyObject *output = NULL;
    if (JS_IsException(result)) {
        JSValue exception = JS_GetException(context);
        const char *message = JS_ToCString(context, exception);
        PyErr_SetString(PyExc_RuntimeError, message ? message : "JavaScript challenge failed");
        if (message) JS_FreeCString(context, message);
        JS_FreeValue(context, exception);
    } else output = PyUnicode_FromString(state.output ? state.output : "");
    JS_FreeValue(context, result);
    free(state.output);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    return output;
}
static PyMethodDef native_methods[] = {
    {"emit", native_emit, METH_VARARGS, NULL},
    {"cancelled", native_cancelled, METH_O, NULL},
    {"media", native_media, METH_VARARGS, NULL},
    {"javascript", native_javascript, METH_VARARGS, NULL},
    {NULL, NULL, 0, NULL}
};
static struct PyModuleDef native_module = { PyModuleDef_HEAD_INIT, "_iy_native", NULL, -1, native_methods };
PyMODINIT_FUNC PyInit__iy_native(void) { return PyModule_Create(&native_module); }

static pthread_mutex_t initialization_lock = PTHREAD_MUTEX_INITIALIZER;
static PyStatus append_search_path(PyConfig *config, const char *path) {
    wchar_t *wide_path = Py_DecodeLocale(path, NULL);
    if (!wide_path) return PyStatus_NoMemory();
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wide_path);
    PyMem_RawFree(wide_path);
    return status;
}
static char *initialize_runtime(const char *home, const char *packages, const char *executable) {
    pthread_mutex_lock(&initialization_lock);
    if (!Py_IsInitialized()) {
        PyImport_AppendInittab("_iy_native", PyInit__iy_native);
        PyConfig config;
        PyConfig_InitIsolatedConfig(&config);
        config.write_bytecode = 0;
        config.site_import = 0;
        config.buffered_stdio = 0;
        config.module_search_paths_set = 1;
        PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
        if (!PyStatus_Exception(status)) status = PyConfig_SetBytesString(&config, &config.executable, executable);
        /* The stdlib directory follows the Python headers this bridge was compiled against. */
        size_t size = strlen(home) + 64;
        char *stdlib = malloc(size);
        if (!stdlib) status = PyStatus_NoMemory();
        else {
            snprintf(stdlib, size, "%s/lib/python%d.%d", home, PY_MAJOR_VERSION, PY_MINOR_VERSION);
            if (!PyStatus_Exception(status)) status = append_search_path(&config, stdlib);
            snprintf(stdlib, size, "%s/lib/python%d.%d/lib-dynload", home, PY_MAJOR_VERSION, PY_MINOR_VERSION);
            if (!PyStatus_Exception(status)) status = append_search_path(&config, stdlib);
            free(stdlib);
        }
        if (!PyStatus_Exception(status)) status = append_search_path(&config, packages);
        if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
        char *failure = PyStatus_Exception(status) ? strdup(status.err_msg ? status.err_msg : "Python initialization failed") : NULL;
        PyConfig_Clear(&config);
        if (failure) { pthread_mutex_unlock(&initialization_lock); return failure; }
        PyEval_SaveThread();
    }
    pthread_mutex_unlock(&initialization_lock);
    return NULL;
}
static char *python_output(PyObject *result) {
    char *output = NULL;
    if (result) {
        const char *text = PyUnicode_AsUTF8(result);
        if (text) output = strdup(text);
    }
    if (!output) {
        PyObject *error = PyErr_GetRaisedException();
        PyObject *message = error ? PyObject_Str(error) : NULL;
        const char *text = message ? PyUnicode_AsUTF8(message) : NULL;
        output = strdup(text ? text : "The native extractor could not start.");
        Py_XDECREF(message);
        Py_XDECREF(error);
    }
    return output;
}
char *iy_dependency_call(const char *home, const char *packages, const char *executable,
                         const char *request) {
    char *failure = initialize_runtime(home, packages, executable);
    if (failure) return failure;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *module = PyImport_ImportModule("iyoinks_dependencies");
    PyObject *function = module ? PyObject_GetAttrString(module, "run") : NULL;
    PyObject *result = function ? PyObject_CallFunction(function, "s", request) : NULL;
    char *output = python_output(result);
    Py_XDECREF(result);
    Py_XDECREF(function);
    Py_XDECREF(module);
    PyGILState_Release(gil);
    return output;
}
static int dependency_activation(const char *action) {
    PyObject *module = PyImport_ImportModule("iyoinks_dependencies");
    PyObject *function = module ? PyObject_GetAttrString(module, "runtime_activation") : NULL;
    PyObject *result = function ? PyObject_CallFunction(function, "s", action) : NULL;
    int success = result != NULL;
    Py_XDECREF(result);
    Py_XDECREF(function);
    Py_XDECREF(module);
    return success;
}
static int media_runtime_state = 0;
static pthread_mutex_t media_initialization_lock = PTHREAD_MUTEX_INITIALIZER;
char *iy_runtime_call(const char *home, const char *packages, const char *executable,
                      IYOperation *operation, const char *request) {
    char *failure = initialize_runtime(home, packages, executable);
    if (failure) return failure;
    pthread_mutex_lock(&media_initialization_lock);
    PyGILState_STATE gil = PyGILState_Ensure();
    if (media_runtime_state < 0) {
        PyGILState_Release(gil);
        pthread_mutex_unlock(&media_initialization_lock);
        return strdup("Source extraction could not start. Reopen the app to retry with the previous dependency version.");
    }
    int first_import = media_runtime_state == 0;
    if (first_import) {
        media_runtime_state = -1;
        if (!dependency_activation("begin")) {
            char *output = python_output(NULL);
            PyGILState_Release(gil);
            pthread_mutex_unlock(&media_initialization_lock);
            return output;
        }
    }
    PyObject *module = PyImport_ImportModule("iyoinks_extract");
    if (first_import && module) {
        PyObject *globals = PyDict_New();
        if (globals) PyDict_SetItemString(globals, "__builtins__", PyEval_GetBuiltins());
        PyObject *smoke = globals ? PyRun_String(
            "import yt_dlp, certifi, yt_dlp_ejs, _iy_native\n"
            "from pathlib import Path\n"
            "with yt_dlp.YoutubeDL({'quiet': True, 'cachedir': False, 'js_runtimes': {}}): pass\n"
            "assert Path(certifi.where()).is_file()\n"
            "assert (Path(yt_dlp_ejs.__file__).parent / 'yt/solver/core.min.js').is_file()\n"
            "assert _iy_native.javascript(None, 'print(1 + 1)') == '2\\n'\n",
            Py_file_input, globals, globals) : NULL;
        if (smoke && dependency_activation("confirm")) media_runtime_state = 1;
        Py_XDECREF(smoke);
        Py_XDECREF(globals);
    }
    if (first_import && media_runtime_state != 1) {
        char *output = python_output(NULL);
        dependency_activation("reject");
        PyErr_Clear();
        Py_XDECREF(module);
        PyGILState_Release(gil);
        pthread_mutex_unlock(&media_initialization_lock);
        return output;
    }
    pthread_mutex_unlock(&media_initialization_lock);
    PyObject *function = module ? PyObject_GetAttrString(module, "run") : NULL;
    PyObject *token = PyCapsule_New(operation, "iYoinks.operation", NULL);
    PyObject *result = function && token ? PyObject_CallFunction(function, "sO", request, token) : NULL;
    char *output = python_output(result);
    Py_XDECREF(result);
    Py_XDECREF(token);
    Py_XDECREF(function);
    Py_XDECREF(module);
    PyGILState_Release(gil);
    return output;
}
