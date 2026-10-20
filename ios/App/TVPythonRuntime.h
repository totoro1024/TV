#ifndef TV_PYTHON_RUNTIME_H
#define TV_PYTHON_RUNTIME_H
int TVPythonInitialize(const char *bundlePythonDirectory);
char *TVPythonCall(const char *method, const char *payload);
void TVPythonFree(char *result);
#endif
