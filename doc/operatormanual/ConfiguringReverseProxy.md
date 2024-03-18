# TLS Termination and Authentication

K2s provides three addons which can be used to expose the functionality implemented inside the kubernetes cluster outside of it: `ingress-nginx`,
`traefik` and `gateway-nginx`.

However, because the whole `k2s` solution relies on a private network, the exposed endpoints are only available inside this private network, running behind the Windows host - regardless which [hosting variant](../../README.md#hosting-variants) is used.

If we want to expose the ingress / gateway endpoints outside of the windows host in a secure manner, we need to configure a reverse proxy on the windows host. The following picture shows this schematically for one of the variants:

![reverse-proxy](./images/reverse-proxy.drawio.png)

We describe here two ways to do that: using the addon `exthttpaccess` and using IIS.

## 1. Using the addon `exthttpaccess`

This k2s addon installs nginx as a windows service on the host, and configures it as a reverse proxy to the installed ingress addon. Products can and must adjust the configuration.

See [NGINX Reverse Proxy](https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/).

Example of using the nginx `http` rewrite configuration.

```conf
...
http {
    server {
        listen localhost:49480;

        location /dashboard {
            rewrite ^/dashboard/?(.*) /$1 break;
            proxy_pass http://k2s-dashboard.local;
        }

        location / {
            rewrite ^/dashboard/?(.*) /$1 break;
            proxy_pass http://kondor.k8s.onehc.net;
        }
    }
}
```

This configuration forwards requests:

* `http://localhost:49480/dashboard/...` -> `http://k2s-dashboard.local/...`
* `http://localhost:49480/others...` -> `http://http://kondor.k8s.onehc.net/others...`

The configuration file is located here: `<k2s-install-dir>\bin\nginx\nginx.conf`

You can use `nssm` to restart the nginx-ext service after changing the configuration file:

```cmd
nssm restart nginx-ext
```

Similar configuration can be used to serve https endpoints, if a certificate is available and configured - see [NGINX SSL Termination](https://docs.nginx.com/nginx/admin-guide/security-controls/terminating-ssl-http/).

Authentication is still work in progress.

## 2. Using IIS

Another way to expose the functionality outside of the windows host is to use the [Application Request Routing module for IIS](https://learn.microsoft.com/en-us/iis/extensions/planning-for-arr/using-the-application-request-routing-module) and the [URL Rewrite IIS Module](https://www.iis.net/downloads/microsoft/url-rewrite) to configure a reverse proxy to the services exposed by the `k2s` ingress or gateway addon.

Using the IIS will ease up integration in the site network environment regarding secure communication and user management, as the IIS can be configured for SSL using the existing host certificate and the NTLM authentication can be configured in IIS.

The Steps to configure the IIS TLS termination and to enable Windows Authentication are:

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

6. Finally, in IIS Manager, navigate to your default site again, select `URL Rewrite`, and create your inbound rules.

   The example below shows how to forward requests to the same two ingress endpoints we used in the previous section.

   ```xml
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
           <rule name="kondor" stopProcessing="true">
             <match url="(.*)" />
             <action type="Rewrite" url="http://kondor.k8s.onehc.net/{R:1}" logRewrittenUrl="true" />
           </rule>
         </rules>
       </rewrite>
     </system.webServer>
   </configuration>
   ```

   This file is found in `C:\inetpub\wwwroot\web.config`.

### Base HREF

When configuring forward proxies, special attention and test effort must be spent to ensure that URLs are properly handled, in case they are pointing to the services being re-directed to.

In our example above, the dashboard service is making several calls to APIs using relative URLs. These API calls work fine only because the `<base href='...'>` is missing in the angular application, so that the application is using the page url and BASE.

For the other rule, the relative URLs are not changed because we redirect a root to another root.

However, in the real world, some applications will encode the BASE URL in their HTML page, and in this case, they need to be adapted before the response is sent back to the clients. In these case, **outbound rewrite rules** are needed to adjust those links in the responses.

See the followinf stack overflow for a pertinent discussion on how the handling of the BASE for Relative URLs shall be done:

<https://stackoverflow.com/questions/2157983/is-there-an-http-header-to-say-what-base-url-to-use-for-relative-links>
