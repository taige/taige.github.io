// Stash HTTP Rewrite Script (request type)
// Intercepts http://fraud-check.stash/ requests,
// uses $httpClient with X-Stash-Selected-Proxy to fetch ippure.com,
// and returns the result as a synthetic response.

const url = $request.url || "";
const match = url.match(/[?&]node=([^&]+)/);
const node = match ? decodeURIComponent(match[1]) : "";
console.log("[fraud-check] url=" + url + " node=" + (node || "(empty)"));
console.log("[ippure] fetching https://my.ippure.com/v1/info via proxy=" + node);

if (!node) {
  $done({
    response: {
      status: 400,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: "missing node parameter" }),
    },
  });
} else {
  $httpClient.get(
    {
      url: "https://my.ippure.com/v1/info",
      timeout: 15,
      headers: {
        "X-Stash-Selected-Proxy": encodeURIComponent(node),
      },
    },
    (error, response, data) => {
      const status = response ? response.status || response.statusCode : "null";
      console.log("[ippure] node=" + node + " status=" + status);
      if (error) {
        console.log("[ippure] ERROR node=" + node + " err=" + error);
        $done({
          response: {
            status: 502,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ error: error.toString(), node: node }),
          },
        });
        return;
      }
      console.log("[ippure] OK node=" + node + " body=" + (data || "").substring(0, 200));
      $done({
        response: {
          status: status || 200,
          headers: { "Content-Type": "application/json" },
          body: data,
        },
      });
    }
  );
}
