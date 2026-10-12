<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:ctx="http://www.bea.com/wli/sb/context" xmlns:ns="http://example.com/integration/contributor/v1" xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">
  <xsl:output method="xml" indent="yes"/>
  <xsl:template match="/">
    <soapenv:Fault>
      <faultcode>soapenv:Server</faultcode>
      <faultstring><xsl:value-of select="//ctx:fault/ctx:reason"/></faultstring>
      <detail><ns:errorCode><xsl:value-of select="//ctx:fault/ctx:errorCode"/></ns:errorCode></detail>
    </soapenv:Fault>
  </xsl:template>
</xsl:stylesheet>
