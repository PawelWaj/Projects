xquery version "3.1";
(:
  fn-bea shim: the Oracle Service Bus XQuery extension functions that OSB flows use most, implemented in XQuery 3.1
  under the ORIGINAL namespace URI, so that an unchanged OSB query runs under Saxon after one added line:

      import module namespace fn-bea = "http://www.bea.com/xquery/xquery-functions" at "fn-bea-shim.xqy";

  Policy: a function either behaves like OSB for the patterns listed, or raises a clear error. It never guesses.
  Functions that depend on the OSB runtime (SQL, credentials, users, groups) are declared here only to fail with a
  message that names the replacement, so a golden test fails loudly instead of silently differing.
:)
module namespace fn-bea = "http://www.bea.com/xquery/xquery-functions";

(: ---------------------------------------------------------------- date / time formatting ---------------------- :)
(: Java SimpleDateFormat pattern -> XPath format-date picture. Covers the tokens OSB flows use; unknown letters error. :)
declare %private function fn-bea:picture($fmt as xs:string) as xs:string {
  let $tokens := analyze-string($fmt, "('[^']*')|(y{1,4}|M{1,4}|d{1,2}|H{1,2}|h{1,2}|m{1,2}|s{1,2}|S{1,3}|a|E{1,4}|Z|X{1,3})|([^yMdHhmsSaEZX']+)")
  return string-join(
    for $m in $tokens/*
    return
      if ($m/self::*:non-match) then error(xs:QName("fn-bea:unsupported-pattern"), concat("fn-bea shim: pattern token not supported: ", string($m), " in ", $fmt))
      else if ($m/*:group[@nr=1]) then replace(substring($m, 2, string-length($m) - 2), "\[", "[[")      (: quoted literal :)
      else if ($m/*:group[@nr=3]) then replace(string($m), "\[", "[[")                                      (: separators :)
      else
        let $t := string($m) return
        switch (true())
          case starts-with($t, "yyyy") return "[Y0001]"
          case starts-with($t, "yy")   return "[Y01]"
          case $t = "y"                return "[Y]"
          case $t = "MMMM"             return "[MNn]"
          case $t = "MMM"              return "[MNn,*-3]"
          case starts-with($t, "MM")   return "[M01]"
          case $t = "M"                return "[M]"
          case $t = "dd"               return "[D01]"
          case $t = "d"                return "[D]"
          case $t = "HH"               return "[H01]"
          case $t = "H"                return "[H]"
          case $t = "hh"               return "[h01]"
          case $t = "h"                return "[h]"
          case $t = "mm"               return "[m01]"
          case $t = "m"                return "[m]"
          case $t = "ss"               return "[s01]"
          case $t = "s"                return "[s]"
          case $t = "SSS"              return "[f001]"
          case $t = "SS"               return "[f01]"
          case $t = "S"                return "[f1]"
          case $t = "a"                return "[PN]"
          case starts-with($t, "EEEE") return "[FNn]"
          case starts-with($t, "E")    return "[FNn,*-3]"
          case $t = "Z"                return "[Z0000]"
          case starts-with($t, "X")    return "[Z]"
          default return error(xs:QName("fn-bea:unsupported-pattern"), concat("fn-bea shim: token ", $t, " in ", $fmt))
  , "")
};

declare function fn-bea:date-to-string-with-format($fmt as xs:string, $date as xs:date?) as xs:string? {
  if (empty($date)) then () else format-date($date, fn-bea:picture($fmt))
};
declare function fn-bea:dateTime-to-string-with-format($fmt as xs:string, $dt as xs:dateTime?) as xs:string? {
  if (empty($dt)) then () else format-dateTime($dt, fn-bea:picture($fmt))
};
declare function fn-bea:time-to-string-with-format($fmt as xs:string, $t as xs:time?) as xs:string? {
  if (empty($t)) then () else format-time($t, fn-bea:picture($fmt))
};

(: Java pattern -> regex with named positions, for the parse direction. Common patterns only. :)
declare %private function fn-bea:parse-parts($fmt as xs:string, $s as xs:string) as map(xs:string, xs:string) {
  let $tokens := analyze-string($fmt, "(yyyy|yy|MM|dd|HH|mm|ss|SSS)|([^yMdHmsS]+)")
  let $names := for $m in $tokens/*:match[*:group[@nr=1]] return string($m)
  let $re := string-join(for $m in $tokens/* return
               if ($m/self::*:non-match) then error(xs:QName("fn-bea:unsupported-pattern"), concat("fn-bea shim parse: ", $fmt))
               else if ($m/*:group[@nr=1]) then (switch (string($m)) case "yyyy" return "(\d{4})" case "SSS" return "(\d{1,3})" default return "(\d{1,2})")
               else replace(string($m), "([.\\+*?\[\]^$(){}|/])", "\\$1"), "")
  let $a := analyze-string($s, concat("^", $re, "$"))
  return if (empty($a/*:match)) then error(xs:QName("fn-bea:parse-failed"), concat("fn-bea shim: '", $s, "' does not match '", $fmt, "'"))
         else map:merge(for $n at $i in $names return map { $n : string($a/*:match/*:group[@nr=$i]) })
};
declare %private function fn-bea:pad2($v as xs:string?) as xs:string { if (empty($v)) then "00" else format-number(xs:integer($v), "00") };

declare function fn-bea:date-from-string-with-format($fmt as xs:string, $s as xs:string?) as xs:date? {
  if (empty($s) or $s = "") then () else
  let $p := fn-bea:parse-parts($fmt, $s)
  let $y := if (map:contains($p, "yyyy")) then $p("yyyy") else concat("20", $p("yy"))
  return xs:date(concat($y, "-", fn-bea:pad2($p("MM")), "-", fn-bea:pad2($p("dd"))))
};
declare function fn-bea:dateTime-from-string-with-format($fmt as xs:string, $s as xs:string?) as xs:dateTime? {
  if (empty($s) or $s = "") then () else
  let $p := fn-bea:parse-parts($fmt, $s)
  let $y := if (map:contains($p, "yyyy")) then $p("yyyy") else concat("20", $p("yy"))
  return xs:dateTime(concat($y, "-", fn-bea:pad2($p("MM")), "-", fn-bea:pad2($p("dd")), "T",
                            fn-bea:pad2($p("HH")), ":", fn-bea:pad2($p("mm")), ":", fn-bea:pad2($p("ss"))))
};

(: ---------------------------------------------------------------- strings ------------------------------------- :)
(: OSB trim removes leading and trailing whitespace only; normalize-space would also collapse inner runs. :)
declare function fn-bea:trim($s as xs:string?) as xs:string? { if (empty($s)) then () else replace($s, "^\s+|\s+$", "") };
declare function fn-bea:trim-left($s as xs:string?) as xs:string? { if (empty($s)) then () else replace($s, "^\s+", "") };
declare function fn-bea:trim-right($s as xs:string?) as xs:string? { if (empty($s)) then () else replace($s, "\s+$", "") };

(: ---------------------------------------------------------------- XML in strings ---------------------------- :)
declare function fn-bea:inlinedXML($s as xs:string?) as node()* { if (empty($s)) then () else parse-xml($s)/node() };
declare function fn-bea:serialize($n as node()?) as xs:string? { if (empty($n)) then () else serialize($n) };

(: ---------------------------------------------------------------- identifiers ---------------------------------- :)
(: Not reproducible by definition; always in the parity ignore list. Prefer binding a Camel-generated header. :)
declare function fn-bea:uuid() as xs:string {
  let $g := random-number-generator()
  let $hex := function($n as xs:integer) as xs:string {
      string-join(for $i in 1 to $n return substring("0123456789abcdef", xs:integer(floor($g?permute(1 to 16)[1])), 1), "") }
  return concat($hex(8), "-", $hex(4), "-4", $hex(3), "-a", $hex(3), "-", $hex(12))
};
declare function fn-bea:generate-guid() as xs:string { fn-bea:uuid() };

(: ---------------------------------------------------------------- deliberately not implemented ---------------- :)
declare function fn-bea:execute-sql($ds as xs:string, $row as xs:QName, $sql as xs:string, $params as item()*) as element()* {
  error(xs:QName("fn-bea:not-implemented"), "fn-bea:execute-sql: replace with a sql: endpoint step before the transform and pass the rows as an external variable")
};
declare function fn-bea:lookupBasicCredentials($ref as xs:string) as element()? {
  error(xs:QName("fn-bea:not-implemented"), "fn-bea:lookupBasicCredentials: credentials come from Vault-delivered properties bound as external variables")
};
declare function fn-bea:isUserInGroup($user as xs:string, $group as xs:string) as xs:boolean {
  error(xs:QName("fn-bea:not-implemented"), "fn-bea:isUserInGroup: authorization moved to the gateway/mesh; record on the flow card")
};
declare function fn-bea:isUserInRole($user as xs:string, $role as xs:string) as xs:boolean {
  error(xs:QName("fn-bea:not-implemented"), "fn-bea:isUserInRole: authorization moved to the gateway/mesh; record on the flow card")
};
