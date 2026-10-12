xquery version "1.0" encoding "utf-8";
(:: OracleAnnotationVersion "1.0" ::)
declare namespace ns = "http://example.com/integration/contributor/v1";
declare namespace mem = "http://example.com/member/v2";
declare variable $member as element(mem:lookupMemberResponse) external;
declare variable $contributorId as xs:string external;

declare function local:toContributor($member as element(mem:lookupMemberResponse), $contributorId as xs:string) as element(ns:getContributorRequest) {
  <ns:getContributorRequest>
    <ns:contributorId>{ $contributorId }</ns:contributorId>
    <ns:nationalId>{ data($member/mem:nationalId) }</ns:nationalId>
    <ns:fullNameAr>{ concat(data($member/mem:firstNameAr), ' ', data($member/mem:familyNameAr)) }</ns:fullNameAr>
    <ns:dateOfBirth>{ fn-bea:date-to-string-with-format("yyyy-MM-dd", xs:date(data($member/mem:birthDate))) }</ns:dateOfBirth>
    <ns:status>{ if (data($member/mem:status) = 'ACTIVE') then 'A' else 'I' }</ns:status>
    {
      for $e in $member/mem:establishments/mem:establishment
      return <ns:establishment><ns:number>{ data($e/mem:number) }</ns:number><ns:wage>{ xs:decimal(data($e/mem:wage)) }</ns:wage></ns:establishment>
    }
    <ns:lookupTime>{ fn-bea:dateTime-to-string-with-format("yyyy-MM-dd'T'HH:mm:ss", fn:current-dateTime()) }</ns:lookupTime>
  </ns:getContributorRequest>
};

local:toContributor($member, $contributorId)
