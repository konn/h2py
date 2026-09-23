/*
 * GHC RTS initialisation for an extension module, kept in its own translation
 * unit so that Rts.h and Python.h never meet.
 *
 * - hs_init_ghc with RtsOptsAll, --install-signal-handlers=no so that SIGINT
 *   stays Python's, and options from the H2PY_RTS_OPTS environment variable.
 * - hs_exit is never called: the RTS cannot be restarted, Python never unloads
 *   extension modules, and process exit reclaims everything.
 * - keep_cafs is on: the RTS lives in a library whose Haskell code is entered
 *   through foreign exports and adjustors long after initialisation.
 */
#include <Rts.h>

#include <stdlib.h>
#include <string.h>

int h2py_hs_init(const char *module_opts)
{
    static int initialised = 0;
    if (initialised) {
        return 0;
    }
    initialised = 1;

    const char *env = getenv("H2PY_RTS_OPTS");
    const char *base = "--install-signal-handlers=no";
    size_t len = strlen(base) + 1
        + (module_opts ? strlen(module_opts) + 1 : 0)
        + (env ? strlen(env) + 1 : 0) + 1;
    char *opts = malloc(len);
    if (opts == NULL) {
        return -1;
    }
    strcpy(opts, base);
    if (module_opts && *module_opts) {
        strcat(opts, " ");
        strcat(opts, module_opts);
    }
    if (env && *env) {
        strcat(opts, " ");
        strcat(opts, env);
    }

    RtsConfig conf = defaultRtsConfig;
    conf.rts_opts_enabled = RtsOptsAll;
    conf.rts_opts = opts; /* retained: the RTS may keep the pointer */
    conf.rts_hs_main = HS_BOOL_FALSE;
    conf.keep_cafs = HS_BOOL_TRUE;

    static char *argv[] = {"h2py", NULL};
    char **pargv = argv;
    int argc = 1;
    hs_init_ghc(&argc, &pargv, conf);
    return 0;
}

void h2py_free_stable_ptr(void *sp)
{
    hs_free_stable_ptr((HsStablePtr) sp);
}
