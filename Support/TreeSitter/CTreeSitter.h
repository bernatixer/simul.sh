// tree-sitter's C API plus the grammars vendored in Vendor/tree-sitter
// (see scripts/fetch-tree-sitter.sh).
#include "../../Vendor/tree-sitter/core/lib/include/tree_sitter/api.h"

const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tsx(void);
