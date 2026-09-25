import { useCallback, useEffect, useRef, useState } from 'react';
import { invokeOrMock } from '../../lib/ipc';

type LoginStatus = {
  state: string;
  signedIn: boolean;
  message?: string | null;
};

const idleStatus: LoginStatus = {
  state: 'idle',
  signedIn: false,
  message: null,
};

async function readStatus(): Promise<LoginStatus> {
  return invokeOrMock<LoginStatus>('chatgpt_oauth_status', undefined, () => idleStatus);
}

export function ChatGPTLoginControl() {
  const [status, setStatus] = useState<LoginStatus>(idleStatus);
  const [busy, setBusy] = useState(false);
  const pollTimer = useRef<number | null>(null);

  const refresh = useCallback(async () => {
    try {
      const next = await readStatus();
      setStatus(next);
      if (next.signedIn || next.state === 'error') {
        setBusy(false);
      }
      return next;
    } catch (error) {
      setBusy(false);
      setStatus({
        state: 'error',
        signedIn: false,
        message: error instanceof Error ? error.message : String(error),
      });
      return null;
    }
  }, []);

  const stopPolling = useCallback(() => {
    if (pollTimer.current !== null) {
      window.clearInterval(pollTimer.current);
      pollTimer.current = null;
    }
  }, []);

  const startPolling = useCallback(() => {
    stopPolling();
    pollTimer.current = window.setInterval(() => {
      void refresh().then((next) => {
        if (next?.signedIn || next?.state === 'error') {
          stopPolling();
        }
      });
    }, 900);
  }, [refresh, stopPolling]);

  useEffect(() => {
    void refresh();

    const onFocus = () => {
      void refresh();
    };
    const onVisibility = () => {
      if (document.visibilityState === 'visible') void refresh();
    };

    window.addEventListener('focus', onFocus);
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      stopPolling();
      window.removeEventListener('focus', onFocus);
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [refresh, stopPolling]);

  const beginLogin = async () => {
    setBusy(true);
    setStatus({ state: 'opening', signedIn: false, message: null });

    try {
      await invokeOrMock<void>('chatgpt_oauth_begin', undefined, () => undefined);
      startPolling();
    } catch (error) {
      setBusy(false);
      setStatus({
        state: 'error',
        signedIn: false,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const label = status.signedIn
    ? 'GPT 已登录'
    : busy || status.state === 'opening'
      ? '正在打开 GPT…'
      : status.state === 'error'
        ? '重新登录 GPT'
        : '登录 GPT';

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 8,
        margin: '2px 0 12px',
      }}
    >
      <button
        type="button"
        disabled={status.signedIn || busy}
        onClick={() => void beginLogin()}
        style={{
          alignSelf: 'flex-start',
          minHeight: 38,
          padding: '0 18px',
          border: '1px solid var(--ol-line)',
          borderRadius: 10,
          background: status.signedIn ? 'var(--ol-surface-2)' : 'var(--ol-blue)',
          color: status.signedIn ? 'var(--ol-ink-3)' : '#fff',
          fontSize: 13,
          fontWeight: 600,
          cursor: status.signedIn || busy ? 'default' : 'pointer',
        }}
      >
        {label}
      </button>

      {status.state === 'error' && status.message && (
        <div style={{ fontSize: 11.5, lineHeight: 1.55, color: 'var(--ol-danger, #d14343)' }}>
          {status.message}
        </div>
      )}
    </div>
  );
}
