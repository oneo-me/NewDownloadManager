<script lang="ts">
  type PopupState = {
    globalEnabled: boolean;
    siteEnabled: boolean;
    origin: string | null;
  };

  let state: PopupState = {
    globalEnabled: true,
    siteEnabled: true,
    origin: null,
  };

  let loading = true;
  let errorMessage = '';
  let activeTabId: number | undefined;

  async function resolveActiveTabId() {
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    activeTabId = tab?.id;
  }

  async function getState() {
    loading = true;
    errorMessage = '';
    let response: { ok?: boolean; state?: PopupState; error?: string } | undefined;
    try {
      response = await browser.runtime.sendMessage({
        type: 'popup:getState',
        tabId: activeTabId,
      });
    } catch (error) {
      errorMessage = `Background unavailable: ${error instanceof Error ? error.message : String(error)}`;
      loading = false;
      return;
    }

    if (!response?.ok || !response.state) {
      errorMessage = response?.error ?? 'Failed to load state';
      loading = false;
      return;
    }

    state = response.state;
    loading = false;
  }

  async function setGlobalEnabled(value: boolean) {
    let response: { ok?: boolean; state?: PopupState; error?: string } | undefined;
    try {
      response = await browser.runtime.sendMessage({
        type: 'popup:setGlobalEnabled',
        value,
        tabId: activeTabId,
      });
    } catch (error) {
      errorMessage = `Background unavailable: ${error instanceof Error ? error.message : String(error)}`;
      return;
    }

    if (!response?.ok || !response.state) {
      errorMessage = response?.error ?? 'Failed to update global switch';
      return;
    }

    state = response.state;
  }

  async function setSiteEnabled(value: boolean) {
    let response: { ok?: boolean; state?: PopupState; error?: string } | undefined;
    try {
      response = await browser.runtime.sendMessage({
        type: 'popup:setSiteEnabled',
        value,
        tabId: activeTabId,
      });
    } catch (error) {
      errorMessage = `Background unavailable: ${error instanceof Error ? error.message : String(error)}`;
      return;
    }

    if (!response?.ok || !response.state) {
      errorMessage = response?.error ?? 'Failed to update site switch';
      return;
    }

    state = response.state;
  }

  function onGlobalToggle(event: Event) {
    const target = event.target as HTMLInputElement;
    void setGlobalEnabled(target.checked);
  }

  function onSiteToggle(event: Event) {
    const target = event.target as HTMLInputElement;
    void setSiteEnabled(target.checked);
  }

  void (async () => {
    await resolveActiveTabId();
    await getState();
  })();
</script>

<main>
  <h1>NewDownloadManager</h1>

  {#if loading}
    <p class="muted">Loading...</p>
  {:else}
    <section class="card">
      <label class="row">
        <span>全局拦截开关</span>
        <input type="checkbox" checked={state.globalEnabled} on:change={onGlobalToggle} />
      </label>

      <label class="row" class:disabled={!state.globalEnabled || !state.origin}>
        <span>当前站点拦截</span>
        <input
          type="checkbox"
          checked={state.siteEnabled}
          on:change={onSiteToggle}
          disabled={!state.globalEnabled || !state.origin}
        />
      </label>

      <p class="site">{state.origin ?? '当前页面不支持站点规则（如 chrome:// 页面）'}</p>
    </section>

    {#if errorMessage}
      <p class="error">{errorMessage}</p>
    {/if}
  {/if}
</main>
