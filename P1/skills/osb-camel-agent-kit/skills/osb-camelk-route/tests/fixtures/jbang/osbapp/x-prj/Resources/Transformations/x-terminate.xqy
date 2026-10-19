xquery version "1.0" encoding "utf-8";
(:: OracleAnnotationVersion "1.0" ::)
declare namespace ns1="http://TargetNamespace.com/demo";
(:: import schema at "../Schemas/demo-nxsd.xsd" ::)
declare namespace ns2="http://www.example.org/createWorkflow";
declare variable $input as element() (:: schema-element(ns1:Root-Element) ::) external;
declare function local:func($input as element() (:: schema-element(ns1:Root-Element) ::)) as element() {
    <ns2:Request>
        <ns2:Body>
            <ns2:referenceNo>{fn:data($input/ns1:data/ns1:referenceNo)}</ns2:referenceNo>
            <ns2:resource>{fn:data($input/ns1:resource)}</ns2:resource>
            <ns2:totalTerminate>{fn:sum($input/ns1:data/ns1:contributions/ns1:amount)}</ns2:totalTerminate>
            <ns2:cells>{fn:count($input/ns1:data/ns1:matrix/ns1:nestedArray/ns1:nestedArrayItem)}</ns2:cells>
            <ns2:id></ns2:id>
        </ns2:Body>
        <ns2:Header><ns2:correlationId>{fn-bea:uuid()}</ns2:correlationId></ns2:Header>
    </ns2:Request>
};
local:func($input)
