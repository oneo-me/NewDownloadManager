type Settings = {
  globalEnabled: boolean;
  siteRules: Record<string, boolean>;
};

type PopupStateResponse = {
  globalEnabled: boolean;
  siteEnabled: boolean;
  origin: string | null;
};

type PopupMessage =
  | { type: 'popup:getState'; tabId?: number }
  | { type: 'popup:setGlobalEnabled'; value: boolean; tabId?: number }
  | { type: 'popup:setSiteEnabled'; value: boolean; tabId?: number };

const SETTINGS_KEY = 'ndmSettings';
const LOCAL_APP_BASE_URLS = ['http://127.0.0.1:48652', 'http://localhost:48652'] as const;

const DEFAULT_SETTINGS: Settings = {
  globalEnabled: true,
  siteRules: {},
};

type IconState = 'enabled' | 'site-disabled' | 'global-disabled';

const ICON_COLOR: Record<IconState, string> = {
  enabled: '#2FA84F',
  'site-disabled': '#E4B11B',
  'global-disabled': '#D44B4B',
};

function getOrigin(value?: string): string | null {
  if (!value) return null;

  try {
    return new URL(value).origin;
  } catch {
    return null;
  }
}

async function getSettings(): Promise<Settings> {
  const result = await browser.storage.local.get(SETTINGS_KEY);
  const saved = result[SETTINGS_KEY] as Settings | undefined;

  if (!saved) {
    await browser.storage.local.set({ [SETTINGS_KEY]: DEFAULT_SETTINGS });
    return { ...DEFAULT_SETTINGS, siteRules: {} };
  }

  return {
    globalEnabled: saved.globalEnabled ?? true,
    siteRules: saved.siteRules ?? {},
  };
}

async function setSettings(next: Settings): Promise<void> {
  await browser.storage.local.set({ [SETTINGS_KEY]: next });
}

async function getTabOrigin(tabId: number): Promise<string | null> {
  const tab = await browser.tabs.get(tabId);
  return getOrigin(tab.url);
}

function isSiteEnabled(settings: Settings, origin: string | null): boolean {
  if (!origin) return true;
  return settings.siteRules[origin] !== false;
}

function getIconState(settings: Settings, origin: string | null): IconState {
  if (!settings.globalEnabled) return 'global-disabled';
  if (!isSiteEnabled(settings, origin)) return 'site-disabled';
  return 'enabled';
}

function buildIconImageData(size: number, color: string): ImageData {
  const canvas = new OffscreenCanvas(size, size);
  const ctx = canvas.getContext('2d');

  if (!ctx) {
    throw new Error('Failed to create icon canvas context');
  }

  ctx.clearRect(0, 0, size, size);

  const radius = Math.floor(size * 0.44);
  const center = size / 2;

  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.arc(center, center, radius, 0, Math.PI * 2);
  ctx.fill();

  ctx.fillStyle = '#FFFFFF';
  ctx.font = `${Math.floor(size * 0.45)}px sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText('N', center, center + size * 0.02);

  return ctx.getImageData(0, 0, size, size);
}

function buildIconSet(state: IconState): Record<string, ImageData> {
  const color = ICON_COLOR[state];
  const sizes = [16, 32, 48, 128];

  return Object.fromEntries(sizes.map((size) => [String(size), buildIconImageData(size, color)]));
}

async function refreshIconForTab(tabId: number): Promise<void> {
  if (tabId < 0) return;

  const settings = await getSettings();
  const origin = await getTabOrigin(tabId);
  const state = getIconState(settings, origin);

  await browser.action.setIcon({
    tabId,
    imageData: buildIconSet(state),
  });
}

async function refreshActiveTabIcon(): Promise<void> {
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  if (tab?.id === undefined) return;
  await refreshIconForTab(tab.id);
}

async function shouldIntercept(item: Browser.downloads.DownloadItem): Promise<boolean> {
  const settings = await getSettings();
  if (!settings.globalEnabled) return false;

  const origin = getOrigin(item.referrer) ?? getOrigin(item.finalUrl) ?? getOrigin(item.url);
  return isSiteEnabled(settings, origin);
}

async function notifyForwardFailure(item: Browser.downloads.DownloadItem, reason: string): Promise<void> {
  const url = item.finalUrl || item.url || 'unknown';
  const id = `forward-failed-${item.id}-${Date.now()}`;

  await browser.notifications.create(id, {
    type: 'basic',
    title: '发送下载请求失败',
    message: `无法发送到 NewDownloadManager。\n${url}\n${reason}`,
    iconUrl: browser.runtime.getURL('/icon/128.png'),
  });
}

async function suppressBrowserDownload(item: Browser.downloads.DownloadItem): Promise<void> {
  try {
    await browser.downloads.cancel(item.id);
  } catch {
    // Ignore failures to keep suppression best-effort.
  }

  try {
    await browser.downloads.removeFile(item.id);
  } catch {
    // File may not exist yet or may already be removed.
  }

  try {
    await browser.downloads.erase({ id: item.id });
  } catch {
    // Entry may already be gone.
  }
}

type ClientStatus = {
  reachable: boolean;
  enabled: boolean;
  error?: string;
};

async function fetchClientStatus(): Promise<ClientStatus> {
  let lastError = 'unknown';

  for (const baseURL of LOCAL_APP_BASE_URLS) {
    try {
      const response = await fetch(`${baseURL}/interception/status`, {
        method: 'GET',
        cache: 'no-store',
      });

      if (!response.ok) {
        lastError = `status ${response.status}`;
        continue;
      }

      const data = (await response.json()) as { chromeInterceptionEnabled?: boolean };
      if (typeof data.chromeInterceptionEnabled !== 'boolean') {
        lastError = 'invalid status payload';
        continue;
      }

      return {
        reachable: true,
        enabled: data.chromeInterceptionEnabled,
      };
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
  }

  return {
    reachable: false,
    enabled: false,
    error: lastError,
  };
}

async function forwardToLocalApp(item: Browser.downloads.DownloadItem): Promise<void> {
  const payload = {
    type: 'download.intercepted',
    timestamp: Date.now(),
    url: item.finalUrl || item.url,
    originalUrl: item.url,
    filename: item.filename || null,
    mime: item.mime || null,
    totalBytes: item.totalBytes ?? null,
  };

  let lastError = 'unknown';

  for (const baseURL of LOCAL_APP_BASE_URLS) {
    try {
      const response = await fetch(`${baseURL}/downloads/intercepted`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
        },
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        const text = await response.text();
        lastError = `status ${response.status}${text ? `: ${text}` : ''}`;
        continue;
      }

      return;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
  }

  throw new Error(lastError);
}

async function handleDownloadCreated(item: Browser.downloads.DownloadItem): Promise<void> {
  if (!(await shouldIntercept(item))) {
    return;
  }

  const clientStatus = await fetchClientStatus();

  // Client-side browser interception switch is off: allow Chrome default behavior.
  if (clientStatus.reachable && !clientStatus.enabled) {
    return;
  }

  let forwardError: string | null = null;

  if (!clientStatus.reachable) {
    forwardError = `客户端未连接: ${clientStatus.error ?? 'connection failed'}`;
  } else {
    try {
      await forwardToLocalApp(item);
    } catch (error) {
      forwardError = error instanceof Error ? error.message : String(error);
    }
  }

  await suppressBrowserDownload(item);

  if (forwardError) {
    console.error('Failed to forward download to local app:', forwardError);
    try {
      await notifyForwardFailure(item, forwardError);
    } catch (notificationError) {
      console.error('Failed to show forward failure notification:', notificationError);
    }
  }
}

async function getPopupState(tabId: number | undefined): Promise<PopupStateResponse> {
  const settings = await getSettings();

  if (tabId === undefined) {
    return {
      globalEnabled: settings.globalEnabled,
      siteEnabled: true,
      origin: null,
    };
  }

  const origin = await getTabOrigin(tabId);

  return {
    globalEnabled: settings.globalEnabled,
    siteEnabled: isSiteEnabled(settings, origin),
    origin,
  };
}

export default defineBackground(() => {
  browser.runtime.onInstalled.addListener(() => {
    void getSettings();
  });

  browser.downloads.onCreated.addListener((item) => {
    void handleDownloadCreated(item);
  });

  browser.tabs.onActivated.addListener(({ tabId }) => {
    void refreshIconForTab(tabId);
  });

  browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
    if (changeInfo.status === 'complete' || changeInfo.url) {
      void refreshIconForTab(tabId);
    }
  });

  browser.windows.onFocusChanged.addListener(() => {
    void refreshActiveTabIcon();
  });

  browser.runtime.onMessage.addListener((message: PopupMessage, _sender, sendResponse) => {
    if (message?.type === 'popup:getState') {
      void getPopupState(message.tabId)
        .then((state) => sendResponse({ ok: true, state }))
        .catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;
    }

    if (message?.type === 'popup:setGlobalEnabled') {
      void (async () => {
        const settings = await getSettings();
        settings.globalEnabled = Boolean(message.value);
        await setSettings(settings);
        await refreshActiveTabIcon();
        const state = await getPopupState(message.tabId);
        sendResponse({ ok: true, state });
      })().catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;
    }

    if (message?.type === 'popup:setSiteEnabled') {
      void (async () => {
        const tabId = message.tabId;
        if (tabId === undefined) {
          sendResponse({ ok: false, error: 'No active tab context' });
          return;
        }

        const origin = await getTabOrigin(tabId);
        if (!origin) {
          sendResponse({ ok: false, error: 'Unsupported page URL' });
          return;
        }

        const settings = await getSettings();
        settings.siteRules[origin] = Boolean(message.value);
        await setSettings(settings);
        await refreshIconForTab(tabId);

        const state = await getPopupState(tabId);
        sendResponse({ ok: true, state });
      })().catch((error) => sendResponse({ ok: false, error: String(error) }));
      return true;
    }

    return false;
  });

  void refreshActiveTabIcon();
});
