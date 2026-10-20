#include "TVPythonRuntime.h"
#include <Python/Python.h>
#include <CommonCrypto/CommonCryptor.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static PyObject *host;
static int attempted;
static void report_error(void) {
    if (PyErr_Occurred()) {
        PyObject *error=PyErr_GetRaisedException();
        if (error) { fprintf(stderr,"TVPythonRuntime 失败类型=%s\n",Py_TYPE(error)->tp_name);Py_DECREF(error); }
    }
}
static PyObject *crypto_decrypt(PyObject *self, PyObject *args) {
    int mode; Py_buffer key={0}, iv={0}, data={0};
    if (!PyArg_ParseTuple(args,"iy*y*y*",&mode,&key,&iv,&data)) return NULL;
    PyObject *result=NULL; CCCryptorRef cryptor=NULL;
    if ((mode!=2 && mode!=6) || iv.len!=16 || (key.len!=16 && key.len!=24 && key.len!=32)) { PyErr_SetString(PyExc_ValueError,"invalid AES parameters"); goto done; }
    CCCryptorStatus status=CCCryptorCreateWithMode(kCCDecrypt,mode==6?kCCModeCTR:kCCModeCBC,kCCAlgorithmAES,ccNoPadding,iv.buf,key.buf,key.len,NULL,0,0,mode==6?kCCModeOptionCTR_BE:0,&cryptor);
    if (status!=kCCSuccess) { PyErr_SetString(PyExc_ValueError,"AES setup failed"); goto done; }
    result=PyBytes_FromStringAndSize(NULL,data.len+16);
    if (result) {
        size_t written=0,final=0;
        status=CCCryptorUpdate(cryptor,data.buf,data.len,PyBytes_AS_STRING(result),data.len+16,&written);
        if (status==kCCSuccess) status=CCCryptorFinal(cryptor,PyBytes_AS_STRING(result)+written,data.len+16-written,&final);
        if (status!=kCCSuccess || _PyBytes_Resize(&result,written+final)<0) { Py_XDECREF(result);result=NULL;PyErr_SetString(PyExc_ValueError,"AES decode failed"); }
    }
 done:
    if (cryptor) CCCryptorRelease(cryptor);
    PyBuffer_Release(&key);PyBuffer_Release(&iv);PyBuffer_Release(&data);return result;
}
static PyMethodDef methods[]={{"decrypt",crypto_decrypt,METH_VARARGS,"CommonCrypto AES CBC/CTR without padding"},{NULL,NULL,0,NULL}};
static struct PyModuleDef crypto_module={PyModuleDef_HEAD_INIT,"_tvcrypto",NULL,-1,methods};
static PyObject *PyInit_tvcrypto(void) { return PyModule_Create(&crypto_module); }
static int add_path(PyConfig *config,const char *root,const char *suffix) {
    char path[4096];if (snprintf(path,sizeof(path),"%s/%s",root,suffix)>=(int)sizeof(path)) return 0;
    wchar_t *wide=Py_DecodeLocale(path,NULL);if (!wide) return 0;
    PyStatus status=PyWideStringList_Append(&config->module_search_paths,wide);PyMem_RawFree(wide);return !PyStatus_Exception(status);
}
int TVPythonInitialize(const char *root) {
    if (attempted) return host!=NULL;
    attempted=1;
    if (PyImport_AppendInittab("_tvcrypto",PyInit_tvcrypto)==-1) return 0;
    PyConfig config;PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode=0;config.install_signal_handlers=0;config.module_search_paths_set=1;
    PyStatus status=PyConfig_SetBytesString(&config,&config.home,root);
    if (!PyStatus_Exception(status) && add_path(&config,root,"lib/python3.15") && add_path(&config,root,"lib/python3.15/lib-dynload") && add_path(&config,root,"packages") && add_path(&config,root,"plugins")) status=Py_InitializeFromConfig(&config);
    else { PyConfig_Clear(&config);return 0; }
    PyConfig_Clear(&config);if (PyStatus_Exception(status)) return 0;
    host=PyImport_ImportModule("tv_plugin_host");
    int ok=host!=NULL;
    if (!ok) report_error();
    PyEval_SaveThread();return ok;
}
char *TVPythonCall(const char *method,const char *payload) {
    if (!host) return NULL;
    PyGILState_STATE state=PyGILState_Ensure();
    PyObject *value=PyObject_CallMethod(host,"dispatch","ss",method,payload);
    char *copy=NULL;
    if (value) { const char *text=PyUnicode_AsUTF8(value);if(text) copy=strdup(text);Py_DECREF(value); }
    if (PyErr_Occurred()) report_error();
    PyGILState_Release(state);return copy;
}
void TVPythonFree(char *result) { free(result); }
