# Secure Host Access

K2s provides three addons which can be used to expose the functionality implemented inside the kubernetes cluster outside of it: `ingress-nginx`,
`traefik` and `gateway-nginx`.

However, because the whole K2s solution relies on a private network, the exposed endpoints are only available inside this private network, running behind the Windows host - regardless which [hosting variant](../../README.md#hosting-variants) is used.

In this document, we will assume you have enabled the K2s addon `dashboard`, so it is usable on your local host at `http://k2s-dashboard.local`, and we further more assume you have an own product configured in one of the K2s ingress, reachable locally under `http://my-product.local`

If we want to expose the ingress / gateway endpoints outside of the windows host in a secure manner, we need to configure a reverse proxy on the windows host. The following picture shows this schematically for one of the variants:

![reverse-proxy](./images/reverse-proxy.drawio.png)

We describe here two ways to do that: using the addon `exthttpaccess` and using IIS.

## 1. Using the addon `exthttpaccess`

This K2s addon installs nginx as a windows service on the host, and configures it as a reverse proxy to the installed ingress addon. Products shall adjust the configuration.

See [NGINX Reverse Proxy](https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/).

The example shows how to make the K2s dashboard available outside your host under an  **https** endpoint:

* `https://my-host.my-domain.com` -> `http://k2s-dashboard.local`

For this you need a server certificate issued by a trusted authority for the fqdn of your host, in this example `my-host.my-domain.com`

1. enable the K2s addon `exthttpaccess`

2. Update the configuration file `<k2s-install-dir>\bin\nginx\nginx.conf`

   ```conf
   ...
   http {
     server {
       listen 443          ssl;
       server_name         my-host.my-domain.com;
       ssl_certificate     my-host.my-domain.com.crt;
       ssl_certificate_key my-host.my-domain.com.key;
        location / {
         proxy_pass http://k2s-dashboard.local;
       }
     }
   }
   ```

3. Restart nginx-ext using `nssm` after changing the configuration file:

   ```cmd
   nssm restart nginx-ext
   ```

Open Points:

* How can NGINX authenticate users against NTLM? The feature seems to be available, but only for NGINX Plus.

* How can NGINX be configured so that the inbound relative path of applications is different from the relative path in K2s ingress, i.e.

  * `https://my-host.my-domain.com/dashboard` -> `http://k2s-dashboard.local`
  * `https://my-host.my-domain.com/my-product` -> `http://my-product.local`

  See [BASE HREF](#base-href) below.

## 2. Using IIS

Another way to expose the functionality outside of the windows host is to use the [Application Request Routing module for IIS](https://learn.microsoft.com/en-us/iis/extensions/planning-for-arr/using-the-application-request-routing-module) and the [URL Rewrite IIS Module](https://www.iis.net/downloads/microsoft/url-rewrite) to configure a reverse proxy to the services exposed by the K2s ingress or gateway addon.

Using the IIS will ease up integration in the site network environment regarding secure communication and user management, as the IIS can be configured for SSL using the existing host certificate and the NTLM authentication can be configured in IIS.

The example below assumes you have two web applications functioning on the two local ingress endpoints `http://k2s-dashboard.local` and `http://my-product.local`.

It shows how to make these two applications available outside your host over **https** and only after the **user is authenticated** against the local host (i.e. he would also eb allowed to log in on your local host) under these endpoints:

* `https://my-host.my-domain.com/dashboard` -> `http://k2s-dashboard.local`
* `https://my-host.my-domain.com/my-product` -> `http://my-product.local`

Follow these steps:

1. Install the IIS Module  [Url Rewrite](https://www.iis.net/downloads/microsoft/url-rewrite)
2. Install the IIS Module [Application Request Routing](https://www.iis.net/downloads/microsoft/application-request-routing)
3. In IIS Manager, navigate to your default Site and select `bindings` in the `Actions pane` on the right.

   Activate SSL binding for your default site in IIS. You need a server certificate to do that.

   ![iis-site-bindings](images/iis-site-bindings.png)

4. In IIS Manager, navigate to your default site and select `Authentication` in the `IIS` section of the `Features View`.

   Enable `Windows Authentication`:

   ![iis-windows-auth](images/iis-windows-auth.png)

5. In IIS Manager, select your computer (root node) and then select `Application Request Routing Cache` in the `IIS` section of the `Features View`. Then select `Server Proxy Settings...` in the `Actions pane`, and enable the proxy:

   ![iis-proxy-settings](images/iis-proxy-settings.png)

   Also activate the `Reverse rewrite host in response headers`.

6. Finally, in IIS Manager, navigate to your default site again, select `URL Rewrite`, and create your inbound and outbound rules.

The example below shows how to forward requests to two different ingress endpoints, one of them being the K2s dashboard also used in the previous section.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="k2s-dashboard" stopProcessing="true">
          <match url="^dashboard/?(.*)" />
          <serverVariables>
            <set name="HTTP_ACCEPT_ENCODING" value="" />
          </serverVariables>
          <action type="Rewrite" url="http://k2s-dashboard.local/{R:1}" logRewrittenUrl="true" />
        </rule>
        <rule name="my-product" stopProcessing="true">
          <match url="^my-product/?(.*)" />
          <action type="Rewrite" url="http://my-product.local/{R:1}" logRewrittenUrl="true" />
        </rule>
      </rules>
      <outboundRules>
        <rule name="my-product-out" preCondition="isHTML" stopProcessing="true">
          <match filterByTags="Base" pattern="^/?(.*)$" negate="false" />
          <action type="Rewrite" value="/my-product/{R:1}" />
          <conditions>
            <add input="{URL}" pattern="/my-product.*" />
          </conditions>
        </rule>
        <preConditions>
          <remove name="isHTTP" />
          <preCondition name="isHTML">
            <add input="{RESPONSE_CONTENT_TYPE}" pattern="^text/html" />
          </preCondition>
        </preConditions>
      </outboundRules>
    </rewrite>
    <security>
      <authentication>
        <windowsAuthentication enabled="true" />
      </authentication>
    </security>
  </system.webServer>
</configuration>
```

This file is found in `C:\inetpub\wwwroot\web.config`.

Open Points:

* The dashboard web application makes calls to APIs, and in many of them the namespace is used a REST API resource ID, e.g. all PODs of namespace `kubernetes-dashboard` are retrieved with this API call:

  `http://k2s-dashboard.local/api/v1/pod/kubernetes-dashboard`

  Unfortunately, when the user selects `All Namespaces` in the User Interface, the same URL is invoked with a space character (`%20`) as the name of the resource - it seems as this is the convention the developers of the Dashboard made:

  `http://k2s-dashboard.local/api/v1/pod/%20`

  The http specs forbid to have a space at the end on an URL, but it works for some reasons. However, when the rewrite rules kick in, it seems they drop the space and the Application is not working with All namespaces selected.

## Base HREF

When configuring forward proxies, special attention and test effort must be spent to ensure that URLs are properly handled, in case they are pointing to the services being re-directed to.

In our example above, the my-product app is making several calls to APIs using relative URLs.
The app is designed to work `my-product.local`, and encodes the `<base href="/">`.
But when the application is accessed through the secure url, the base url must be rewritten to `<base href="/my-product/">`.

This is solved for my-product by the outbound rule. For the other rule, the relative URLs are not changed because we redirect a root to another root.

However, in the real world, some applications will encode the BASE URL in their HTML page, and in this case, they need to be adapted before the response is sent back to the clients. In these case, **outbound rewrite rules** are needed to adjust those links in the responses.

See the following stack overflow for a pertinent discussion on how the handling of the BASE for Relative URLs shall be done:

<https://stackoverflow.com/questions/2157983/is-there-an-http-header-to-say-what-base-url-to-use-for-relative-links>
