/* SQLITE_TRANSIENT is the "pointer" (destructor)-1, which Zig refuses as
 * a function pointer (misaligned). Binding through C sidesteps it: sqlite
 * copies the bytes, so the caller's buffer may go away right after. */
#include "sqlite3.h"

int kr8_bind_text(sqlite3_stmt *s, int i, const char *p, int n)
{
    return sqlite3_bind_text(s, i, p, n, SQLITE_TRANSIENT);
}
