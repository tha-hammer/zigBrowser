#include <stddef.h>

typedef void CURL;

const char *curl_version(void);
CURL *curl_easy_init(void);
void curl_easy_cleanup(CURL *handle);
