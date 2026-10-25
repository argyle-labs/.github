def valid:
  type == "string"
  and test("\\A(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?\\z");

def stable: valid and (test("[-+]") | not);

def rc: valid and test("\\A[0-9.]+-rc\\.(0|[1-9][0-9]*)\\z");

def key:
  (split("+")[0]) as $v
  | ($v | index("-")) as $i
  | [ (if $i then $v[:$i] else $v end | split(".") | map(tonumber)),
      (if $i then [0, ($v[$i + 1:] | split(".") | map(if test("\\A[0-9]+\\z") then [0, tonumber] else [1, .] end))] else [1] end) ];

def max: map(select(ltrimstr("v") | valid)) | max_by(ltrimstr("v") | key) // empty;
