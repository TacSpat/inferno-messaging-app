var __defProp = Object.defineProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, {
      get: all[name],
      enumerable: true,
      configurable: true,
      set: (newValue) => all[name] = () => newValue
    });
};
var __esm = (fn, res) => () => (fn && (res = fn(fn = 0)), res);

// node_modules/@rails/actioncable/src/adapters.js
var adapters_default;
var init_adapters = __esm(() => {
  adapters_default = {
    logger: typeof console !== "undefined" ? console : undefined,
    WebSocket: typeof WebSocket !== "undefined" ? WebSocket : undefined
  };
});

// node_modules/@rails/actioncable/src/logger.js
var logger_default;
var init_logger = __esm(() => {
  init_adapters();
  logger_default = {
    log(...messages) {
      if (this.enabled) {
        messages.push(Date.now());
        adapters_default.logger.log("[ActionCable]", ...messages);
      }
    }
  };
});

// node_modules/@rails/actioncable/src/connection_monitor.js
class ConnectionMonitor {
  constructor(connection) {
    this.visibilityDidChange = this.visibilityDidChange.bind(this);
    this.connection = connection;
    this.reconnectAttempts = 0;
  }
  start() {
    if (!this.isRunning()) {
      this.startedAt = now();
      delete this.stoppedAt;
      this.startPolling();
      addEventListener("visibilitychange", this.visibilityDidChange);
      logger_default.log(`ConnectionMonitor started. stale threshold = ${this.constructor.staleThreshold} s`);
    }
  }
  stop() {
    if (this.isRunning()) {
      this.stoppedAt = now();
      this.stopPolling();
      removeEventListener("visibilitychange", this.visibilityDidChange);
      logger_default.log("ConnectionMonitor stopped");
    }
  }
  isRunning() {
    return this.startedAt && !this.stoppedAt;
  }
  recordMessage() {
    this.pingedAt = now();
  }
  recordConnect() {
    this.reconnectAttempts = 0;
    delete this.disconnectedAt;
    logger_default.log("ConnectionMonitor recorded connect");
  }
  recordDisconnect() {
    this.disconnectedAt = now();
    logger_default.log("ConnectionMonitor recorded disconnect");
  }
  startPolling() {
    this.stopPolling();
    this.poll();
  }
  stopPolling() {
    clearTimeout(this.pollTimeout);
  }
  poll() {
    this.pollTimeout = setTimeout(() => {
      this.reconnectIfStale();
      this.poll();
    }, this.getPollInterval());
  }
  getPollInterval() {
    const { staleThreshold, reconnectionBackoffRate } = this.constructor;
    const backoff = Math.pow(1 + reconnectionBackoffRate, Math.min(this.reconnectAttempts, 10));
    const jitterMax = this.reconnectAttempts === 0 ? 1 : reconnectionBackoffRate;
    const jitter = jitterMax * Math.random();
    return staleThreshold * 1000 * backoff * (1 + jitter);
  }
  reconnectIfStale() {
    if (this.connectionIsStale()) {
      logger_default.log(`ConnectionMonitor detected stale connection. reconnectAttempts = ${this.reconnectAttempts}, time stale = ${secondsSince(this.refreshedAt)} s, stale threshold = ${this.constructor.staleThreshold} s`);
      this.reconnectAttempts++;
      if (this.disconnectedRecently()) {
        logger_default.log(`ConnectionMonitor skipping reopening recent disconnect. time disconnected = ${secondsSince(this.disconnectedAt)} s`);
      } else {
        logger_default.log("ConnectionMonitor reopening");
        this.connection.reopen();
      }
    }
  }
  get refreshedAt() {
    return this.pingedAt ? this.pingedAt : this.startedAt;
  }
  connectionIsStale() {
    return secondsSince(this.refreshedAt) > this.constructor.staleThreshold;
  }
  disconnectedRecently() {
    return this.disconnectedAt && secondsSince(this.disconnectedAt) < this.constructor.staleThreshold;
  }
  visibilityDidChange() {
    if (document.visibilityState === "visible") {
      setTimeout(() => {
        if (this.connectionIsStale() || !this.connection.isOpen()) {
          logger_default.log(`ConnectionMonitor reopening stale connection on visibilitychange. visibilityState = ${document.visibilityState}`);
          this.connection.reopen();
        }
      }, 200);
    }
  }
}
var now = () => new Date().getTime(), secondsSince = (time) => (now() - time) / 1000, connection_monitor_default;
var init_connection_monitor = __esm(() => {
  init_logger();
  ConnectionMonitor.staleThreshold = 6;
  ConnectionMonitor.reconnectionBackoffRate = 0.15;
  connection_monitor_default = ConnectionMonitor;
});

// node_modules/@rails/actioncable/src/internal.js
var internal_default;
var init_internal = __esm(() => {
  internal_default = {
    message_types: {
      welcome: "welcome",
      disconnect: "disconnect",
      ping: "ping",
      confirmation: "confirm_subscription",
      rejection: "reject_subscription"
    },
    disconnect_reasons: {
      unauthorized: "unauthorized",
      invalid_request: "invalid_request",
      server_restart: "server_restart",
      remote: "remote"
    },
    default_mount_path: "/cable",
    protocols: [
      "actioncable-v1-json",
      "actioncable-unsupported"
    ]
  };
});

// node_modules/@rails/actioncable/src/connection.js
class Connection {
  constructor(consumer) {
    this.open = this.open.bind(this);
    this.consumer = consumer;
    this.subscriptions = this.consumer.subscriptions;
    this.monitor = new connection_monitor_default(this);
    this.disconnected = true;
  }
  send(data) {
    if (this.isOpen()) {
      this.webSocket.send(JSON.stringify(data));
      return true;
    } else {
      return false;
    }
  }
  open() {
    if (this.isActive()) {
      logger_default.log(`Attempted to open WebSocket, but existing socket is ${this.getState()}`);
      return false;
    } else {
      const socketProtocols = [...protocols, ...this.consumer.subprotocols || []];
      logger_default.log(`Opening WebSocket, current state is ${this.getState()}, subprotocols: ${socketProtocols}`);
      if (this.webSocket) {
        this.uninstallEventHandlers();
      }
      this.webSocket = new adapters_default.WebSocket(this.consumer.url, socketProtocols);
      this.installEventHandlers();
      this.monitor.start();
      return true;
    }
  }
  close({ allowReconnect } = { allowReconnect: true }) {
    if (!allowReconnect) {
      this.monitor.stop();
    }
    if (this.isOpen()) {
      return this.webSocket.close();
    }
  }
  reopen() {
    logger_default.log(`Reopening WebSocket, current state is ${this.getState()}`);
    if (this.isActive()) {
      try {
        return this.close();
      } catch (error) {
        logger_default.log("Failed to reopen WebSocket", error);
      } finally {
        logger_default.log(`Reopening WebSocket in ${this.constructor.reopenDelay}ms`);
        setTimeout(this.open, this.constructor.reopenDelay);
      }
    } else {
      return this.open();
    }
  }
  getProtocol() {
    if (this.webSocket) {
      return this.webSocket.protocol;
    }
  }
  isOpen() {
    return this.isState("open");
  }
  isActive() {
    return this.isState("open", "connecting");
  }
  triedToReconnect() {
    return this.monitor.reconnectAttempts > 0;
  }
  isProtocolSupported() {
    return indexOf.call(supportedProtocols, this.getProtocol()) >= 0;
  }
  isState(...states) {
    return indexOf.call(states, this.getState()) >= 0;
  }
  getState() {
    if (this.webSocket) {
      for (let state in adapters_default.WebSocket) {
        if (adapters_default.WebSocket[state] === this.webSocket.readyState) {
          return state.toLowerCase();
        }
      }
    }
    return null;
  }
  installEventHandlers() {
    for (let eventName in this.events) {
      const handler = this.events[eventName].bind(this);
      this.webSocket[`on${eventName}`] = handler;
    }
  }
  uninstallEventHandlers() {
    for (let eventName in this.events) {
      this.webSocket[`on${eventName}`] = function() {
      };
    }
  }
}
var message_types, protocols, supportedProtocols, indexOf, connection_default;
var init_connection = __esm(() => {
  init_adapters();
  init_connection_monitor();
  init_internal();
  init_logger();
  ({ message_types, protocols } = internal_default);
  supportedProtocols = protocols.slice(0, protocols.length - 1);
  indexOf = [].indexOf;
  Connection.reopenDelay = 500;
  Connection.prototype.events = {
    message(event) {
      if (!this.isProtocolSupported()) {
        return;
      }
      const { identifier, message, reason, reconnect, type } = JSON.parse(event.data);
      this.monitor.recordMessage();
      switch (type) {
        case message_types.welcome:
          if (this.triedToReconnect()) {
            this.reconnectAttempted = true;
          }
          this.monitor.recordConnect();
          return this.subscriptions.reload();
        case message_types.disconnect:
          logger_default.log(`Disconnecting. Reason: ${reason}`);
          return this.close({ allowReconnect: reconnect });
        case message_types.ping:
          return null;
        case message_types.confirmation:
          this.subscriptions.confirmSubscription(identifier);
          if (this.reconnectAttempted) {
            this.reconnectAttempted = false;
            return this.subscriptions.notify(identifier, "connected", { reconnected: true });
          } else {
            return this.subscriptions.notify(identifier, "connected", { reconnected: false });
          }
        case message_types.rejection:
          return this.subscriptions.reject(identifier);
        default:
          return this.subscriptions.notify(identifier, "received", message);
      }
    },
    open() {
      logger_default.log(`WebSocket onopen event, using '${this.getProtocol()}' subprotocol`);
      this.disconnected = false;
      if (!this.isProtocolSupported()) {
        logger_default.log("Protocol is unsupported. Stopping monitor and disconnecting.");
        return this.close({ allowReconnect: false });
      }
    },
    close(event) {
      logger_default.log("WebSocket onclose event");
      if (this.disconnected) {
        return;
      }
      this.disconnected = true;
      this.monitor.recordDisconnect();
      return this.subscriptions.notifyAll("disconnected", { willAttemptReconnect: this.monitor.isRunning() });
    },
    error() {
      logger_default.log("WebSocket onerror event");
    }
  };
  connection_default = Connection;
});

// node_modules/@rails/actioncable/src/subscription.js
class Subscription {
  constructor(consumer, params = {}, mixin) {
    this.consumer = consumer;
    this.identifier = JSON.stringify(params);
    extend(this, mixin);
  }
  perform(action, data = {}) {
    data.action = action;
    return this.send(data);
  }
  send(data) {
    return this.consumer.send({ command: "message", identifier: this.identifier, data: JSON.stringify(data) });
  }
  unsubscribe() {
    return this.consumer.subscriptions.remove(this);
  }
}
var extend = function(object, properties) {
  if (properties != null) {
    for (let key in properties) {
      const value = properties[key];
      object[key] = value;
    }
  }
  return object;
};

// node_modules/@rails/actioncable/src/subscription_guarantor.js
class SubscriptionGuarantor {
  constructor(subscriptions) {
    this.subscriptions = subscriptions;
    this.pendingSubscriptions = [];
  }
  guarantee(subscription) {
    if (this.pendingSubscriptions.indexOf(subscription) == -1) {
      logger_default.log(`SubscriptionGuarantor guaranteeing ${subscription.identifier}`);
      this.pendingSubscriptions.push(subscription);
    } else {
      logger_default.log(`SubscriptionGuarantor already guaranteeing ${subscription.identifier}`);
    }
    this.startGuaranteeing();
  }
  forget(subscription) {
    logger_default.log(`SubscriptionGuarantor forgetting ${subscription.identifier}`);
    this.pendingSubscriptions = this.pendingSubscriptions.filter((s) => s !== subscription);
  }
  startGuaranteeing() {
    this.stopGuaranteeing();
    this.retrySubscribing();
  }
  stopGuaranteeing() {
    clearTimeout(this.retryTimeout);
  }
  retrySubscribing() {
    this.retryTimeout = setTimeout(() => {
      if (this.subscriptions && typeof this.subscriptions.subscribe === "function") {
        this.pendingSubscriptions.map((subscription) => {
          logger_default.log(`SubscriptionGuarantor resubscribing ${subscription.identifier}`);
          this.subscriptions.subscribe(subscription);
        });
      }
    }, 500);
  }
}
var subscription_guarantor_default;
var init_subscription_guarantor = __esm(() => {
  init_logger();
  subscription_guarantor_default = SubscriptionGuarantor;
});

// node_modules/@rails/actioncable/src/subscriptions.js
class Subscriptions {
  constructor(consumer) {
    this.consumer = consumer;
    this.guarantor = new subscription_guarantor_default(this);
    this.subscriptions = [];
  }
  create(channelName, mixin) {
    const channel = channelName;
    const params = typeof channel === "object" ? channel : { channel };
    const subscription = new Subscription(this.consumer, params, mixin);
    return this.add(subscription);
  }
  add(subscription) {
    this.subscriptions.push(subscription);
    this.consumer.ensureActiveConnection();
    this.notify(subscription, "initialized");
    this.subscribe(subscription);
    return subscription;
  }
  remove(subscription) {
    this.forget(subscription);
    if (!this.findAll(subscription.identifier).length) {
      this.sendCommand(subscription, "unsubscribe");
    }
    return subscription;
  }
  reject(identifier) {
    return this.findAll(identifier).map((subscription) => {
      this.forget(subscription);
      this.notify(subscription, "rejected");
      return subscription;
    });
  }
  forget(subscription) {
    this.guarantor.forget(subscription);
    this.subscriptions = this.subscriptions.filter((s) => s !== subscription);
    return subscription;
  }
  findAll(identifier) {
    return this.subscriptions.filter((s) => s.identifier === identifier);
  }
  reload() {
    return this.subscriptions.map((subscription) => this.subscribe(subscription));
  }
  notifyAll(callbackName, ...args) {
    return this.subscriptions.map((subscription) => this.notify(subscription, callbackName, ...args));
  }
  notify(subscription, callbackName, ...args) {
    let subscriptions;
    if (typeof subscription === "string") {
      subscriptions = this.findAll(subscription);
    } else {
      subscriptions = [subscription];
    }
    return subscriptions.map((subscription2) => typeof subscription2[callbackName] === "function" ? subscription2[callbackName](...args) : undefined);
  }
  subscribe(subscription) {
    if (this.sendCommand(subscription, "subscribe")) {
      this.guarantor.guarantee(subscription);
    }
  }
  confirmSubscription(identifier) {
    logger_default.log(`Subscription confirmed ${identifier}`);
    this.findAll(identifier).map((subscription) => this.guarantor.forget(subscription));
  }
  sendCommand(subscription, command) {
    const { identifier } = subscription;
    return this.consumer.send({ command, identifier });
  }
}
var init_subscriptions = __esm(() => {
  init_subscription_guarantor();
  init_logger();
});

// node_modules/@rails/actioncable/src/consumer.js
class Consumer {
  constructor(url) {
    this._url = url;
    this.subscriptions = new Subscriptions(this);
    this.connection = new connection_default(this);
    this.subprotocols = [];
  }
  get url() {
    return createWebSocketURL(this._url);
  }
  send(data) {
    return this.connection.send(data);
  }
  connect() {
    return this.connection.open();
  }
  disconnect() {
    return this.connection.close({ allowReconnect: false });
  }
  ensureActiveConnection() {
    if (!this.connection.isActive()) {
      return this.connection.open();
    }
  }
  addSubProtocol(subprotocol) {
    this.subprotocols = [...this.subprotocols, subprotocol];
  }
}
function createWebSocketURL(url) {
  if (typeof url === "function") {
    url = url();
  }
  if (url && !/^wss?:/i.test(url)) {
    const a = document.createElement("a");
    a.href = url;
    a.href = a.href;
    a.protocol = a.protocol.replace("http", "ws");
    return a.href;
  } else {
    return url;
  }
}
var init_consumer = __esm(() => {
  init_connection();
  init_subscriptions();
});

// node_modules/@rails/actioncable/src/index.js
var exports_src = {};
__export(exports_src, {
  logger: () => logger_default,
  getConfig: () => getConfig,
  createWebSocketURL: () => createWebSocketURL,
  createConsumer: () => createConsumer,
  adapters: () => adapters_default,
  Subscriptions: () => Subscriptions,
  SubscriptionGuarantor: () => subscription_guarantor_default,
  Subscription: () => Subscription,
  INTERNAL: () => internal_default,
  Consumer: () => Consumer,
  ConnectionMonitor: () => connection_monitor_default,
  Connection: () => connection_default
});
function createConsumer(url = getConfig("url") || internal_default.default_mount_path) {
  return new Consumer(url);
}
function getConfig(name) {
  const element = document.head.querySelector(`meta[name='action-cable-${name}']`);
  if (element) {
    return element.getAttribute("content");
  }
}
var init_src = __esm(() => {
  init_connection();
  init_connection_monitor();
  init_consumer();
  init_internal();
  init_subscriptions();
  init_subscription_guarantor();
  init_adapters();
  init_logger();
});

// node_modules/@hotwired/turbo/dist/turbo.es2017-esm.js
var exports_turbo_es2017_esm = {};
__export(exports_turbo_es2017_esm, {
  visit: () => visit,
  start: () => start,
  setProgressBarDelay: () => setProgressBarDelay,
  setFormMode: () => setFormMode,
  setConfirmMethod: () => setConfirmMethod,
  session: () => session,
  renderStreamMessage: () => renderStreamMessage,
  registerAdapter: () => registerAdapter,
  navigator: () => sessionNavigator,
  morphTurboFrameElements: () => morphTurboFrameElements,
  morphElements: () => morphElements,
  morphChildren: () => morphChildren,
  morphBodyElements: () => morphBodyElements,
  isSafe: () => isSafe,
  fetchMethodFromString: () => fetchMethodFromString,
  fetchEnctypeFromString: () => fetchEnctypeFromString,
  fetch: () => fetchWithTurboHeaders,
  disconnectStreamSource: () => disconnectStreamSource,
  connectStreamSource: () => connectStreamSource,
  config: () => config,
  cache: () => cache,
  StreamSourceElement: () => StreamSourceElement,
  StreamElement: () => StreamElement,
  StreamActions: () => StreamActions,
  PageSnapshot: () => PageSnapshot,
  PageRenderer: () => PageRenderer,
  FrameRenderer: () => FrameRenderer,
  FrameLoadingStyle: () => FrameLoadingStyle,
  FrameElement: () => FrameElement,
  FetchResponse: () => FetchResponse,
  FetchRequest: () => FetchRequest,
  FetchMethod: () => FetchMethod,
  FetchEnctype: () => FetchEnctype
});
/*!
Turbo 8.0.23
Copyright © 2026 37signals LLC
 */
var FrameLoadingStyle = {
  eager: "eager",
  lazy: "lazy"
};

class FrameElement extends HTMLElement {
  static delegateConstructor = undefined;
  loaded = Promise.resolve();
  static get observedAttributes() {
    return ["disabled", "loading", "src"];
  }
  constructor() {
    super();
    this.delegate = new FrameElement.delegateConstructor(this);
  }
  connectedCallback() {
    this.delegate.connect();
  }
  disconnectedCallback() {
    this.delegate.disconnect();
  }
  reload() {
    return this.delegate.sourceURLReloaded();
  }
  attributeChangedCallback(name) {
    if (name == "loading") {
      this.delegate.loadingStyleChanged();
    } else if (name == "src") {
      this.delegate.sourceURLChanged();
    } else if (name == "disabled") {
      this.delegate.disabledChanged();
    }
  }
  get src() {
    return this.getAttribute("src");
  }
  set src(value) {
    if (value) {
      this.setAttribute("src", value);
    } else {
      this.removeAttribute("src");
    }
  }
  get refresh() {
    return this.getAttribute("refresh");
  }
  set refresh(value) {
    if (value) {
      this.setAttribute("refresh", value);
    } else {
      this.removeAttribute("refresh");
    }
  }
  get shouldReloadWithMorph() {
    return this.src && this.refresh === "morph";
  }
  get loading() {
    return frameLoadingStyleFromString(this.getAttribute("loading") || "");
  }
  set loading(value) {
    if (value) {
      this.setAttribute("loading", value);
    } else {
      this.removeAttribute("loading");
    }
  }
  get disabled() {
    return this.hasAttribute("disabled");
  }
  set disabled(value) {
    if (value) {
      this.setAttribute("disabled", "");
    } else {
      this.removeAttribute("disabled");
    }
  }
  get autoscroll() {
    return this.hasAttribute("autoscroll");
  }
  set autoscroll(value) {
    if (value) {
      this.setAttribute("autoscroll", "");
    } else {
      this.removeAttribute("autoscroll");
    }
  }
  get complete() {
    return !this.delegate.isLoading;
  }
  get isActive() {
    return this.ownerDocument === document && !this.isPreview;
  }
  get isPreview() {
    return this.ownerDocument?.documentElement?.hasAttribute("data-turbo-preview");
  }
}
function frameLoadingStyleFromString(style) {
  switch (style.toLowerCase()) {
    case "lazy":
      return FrameLoadingStyle.lazy;
    default:
      return FrameLoadingStyle.eager;
  }
}
var drive = {
  enabled: true,
  progressBarDelay: 500,
  unvisitableExtensions: new Set([
    ".7z",
    ".aac",
    ".apk",
    ".avi",
    ".bmp",
    ".bz2",
    ".css",
    ".csv",
    ".deb",
    ".dmg",
    ".doc",
    ".docx",
    ".exe",
    ".gif",
    ".gz",
    ".heic",
    ".heif",
    ".ico",
    ".iso",
    ".jpeg",
    ".jpg",
    ".js",
    ".json",
    ".m4a",
    ".mkv",
    ".mov",
    ".mp3",
    ".mp4",
    ".mpeg",
    ".mpg",
    ".msi",
    ".ogg",
    ".ogv",
    ".pdf",
    ".pkg",
    ".png",
    ".ppt",
    ".pptx",
    ".rar",
    ".rtf",
    ".svg",
    ".tar",
    ".tif",
    ".tiff",
    ".txt",
    ".wav",
    ".webm",
    ".webp",
    ".wma",
    ".wmv",
    ".xls",
    ".xlsx",
    ".xml",
    ".zip"
  ])
};
function activateScriptElement(element) {
  if (element.getAttribute("data-turbo-eval") == "false") {
    return element;
  } else {
    const createdScriptElement = document.createElement("script");
    const cspNonce = getCspNonce();
    if (cspNonce) {
      createdScriptElement.nonce = cspNonce;
    }
    createdScriptElement.textContent = element.textContent;
    createdScriptElement.async = false;
    copyElementAttributes(createdScriptElement, element);
    return createdScriptElement;
  }
}
function copyElementAttributes(destinationElement, sourceElement) {
  for (const { name, value } of sourceElement.attributes) {
    destinationElement.setAttribute(name, value);
  }
}
function createDocumentFragment(html) {
  const template = document.createElement("template");
  template.innerHTML = html;
  return template.content;
}
function dispatch(eventName, { target, cancelable, detail } = {}) {
  const event = new CustomEvent(eventName, {
    cancelable,
    bubbles: true,
    composed: true,
    detail
  });
  if (target && target.isConnected) {
    target.dispatchEvent(event);
  } else {
    document.documentElement.dispatchEvent(event);
  }
  return event;
}
function cancelEvent(event) {
  event.preventDefault();
  event.stopImmediatePropagation();
}
function nextRepaint() {
  if (document.visibilityState === "hidden") {
    return nextEventLoopTick();
  } else {
    return nextAnimationFrame();
  }
}
function nextAnimationFrame() {
  return new Promise((resolve) => requestAnimationFrame(() => resolve()));
}
function nextEventLoopTick() {
  return new Promise((resolve) => setTimeout(() => resolve(), 0));
}
function parseHTMLDocument(html = "") {
  return new DOMParser().parseFromString(html, "text/html");
}
function unindent(strings, ...values) {
  const lines = interpolate(strings, values).replace(/^\n/, "").split(`
`);
  const match = lines[0].match(/^\s+/);
  const indent = match ? match[0].length : 0;
  return lines.map((line) => line.slice(indent)).join(`
`);
}
function interpolate(strings, values) {
  return strings.reduce((result, string, i) => {
    const value = values[i] == undefined ? "" : values[i];
    return result + string + value;
  }, "");
}
function uuid() {
  return Array.from({ length: 36 }).map((_, i) => {
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      return "-";
    } else if (i == 14) {
      return "4";
    } else if (i == 19) {
      return (Math.floor(Math.random() * 4) + 8).toString(16);
    } else {
      return Math.floor(Math.random() * 16).toString(16);
    }
  }).join("");
}
function getAttribute(attributeName, ...elements) {
  for (const value of elements.map((element) => element?.getAttribute(attributeName))) {
    if (typeof value == "string")
      return value;
  }
  return null;
}
function hasAttribute(attributeName, ...elements) {
  return elements.some((element) => element && element.hasAttribute(attributeName));
}
function markAsBusy(...elements) {
  for (const element of elements) {
    if (element.localName == "turbo-frame") {
      element.setAttribute("busy", "");
    }
    element.setAttribute("aria-busy", "true");
  }
}
function clearBusyState(...elements) {
  for (const element of elements) {
    if (element.localName == "turbo-frame") {
      element.removeAttribute("busy");
    }
    element.removeAttribute("aria-busy");
  }
}
function waitForLoad(element, timeoutInMilliseconds = 2000) {
  return new Promise((resolve) => {
    const onComplete = () => {
      element.removeEventListener("error", onComplete);
      element.removeEventListener("load", onComplete);
      resolve();
    };
    element.addEventListener("load", onComplete, { once: true });
    element.addEventListener("error", onComplete, { once: true });
    setTimeout(resolve, timeoutInMilliseconds);
  });
}
function getHistoryMethodForAction(action) {
  switch (action) {
    case "replace":
      return history.replaceState;
    case "advance":
    case "restore":
      return history.pushState;
  }
}
function isAction(action) {
  return action == "advance" || action == "replace" || action == "restore";
}
function getVisitAction(...elements) {
  const action = getAttribute("data-turbo-action", ...elements);
  return isAction(action) ? action : null;
}
function getMetaElement(name) {
  return document.querySelector(`meta[name="${name}"]`);
}
function getMetaContent(name) {
  const element = getMetaElement(name);
  return element && element.content;
}
function getCspNonce() {
  const element = getMetaElement("csp-nonce");
  if (element) {
    const { nonce, content } = element;
    return nonce == "" ? content : nonce;
  }
}
function setMetaContent(name, content) {
  let element = getMetaElement(name);
  if (!element) {
    element = document.createElement("meta");
    element.setAttribute("name", name);
    document.head.appendChild(element);
  }
  element.setAttribute("content", content);
  return element;
}
function findClosestRecursively(element, selector) {
  if (element instanceof Element) {
    return element.closest(selector) || findClosestRecursively(element.assignedSlot || element.getRootNode()?.host, selector);
  }
}
function elementIsFocusable(element) {
  const inertDisabledOrHidden = "[inert], :disabled, [hidden], details:not([open]), dialog:not([open])";
  return !!element && element.closest(inertDisabledOrHidden) == null && typeof element.focus == "function";
}
function queryAutofocusableElement(elementOrDocumentFragment) {
  return Array.from(elementOrDocumentFragment.querySelectorAll("[autofocus]")).find(elementIsFocusable);
}
async function around(callback, reader) {
  const before = reader();
  callback();
  await nextAnimationFrame();
  const after = reader();
  return [before, after];
}
function doesNotTargetIFrame(name) {
  if (name === "_blank") {
    return false;
  } else if (name) {
    for (const element of document.getElementsByName(name)) {
      if (element instanceof HTMLIFrameElement)
        return false;
    }
    return true;
  } else {
    return true;
  }
}
function findLinkFromClickTarget(target) {
  const link = findClosestRecursively(target, "a[href], a[xlink\\:href]");
  if (!link)
    return null;
  if (link.href.startsWith("#"))
    return null;
  if (link.hasAttribute("download"))
    return null;
  const linkTarget = link.getAttribute("target");
  if (linkTarget && linkTarget !== "_self")
    return null;
  return link;
}
function debounce(fn, delay) {
  let timeoutId = null;
  return (...args) => {
    const callback = () => fn.apply(this, args);
    clearTimeout(timeoutId);
    timeoutId = setTimeout(callback, delay);
  };
}
var submitter = {
  "aria-disabled": {
    beforeSubmit: (submitter2) => {
      submitter2.setAttribute("aria-disabled", "true");
      submitter2.addEventListener("click", cancelEvent);
    },
    afterSubmit: (submitter2) => {
      submitter2.removeAttribute("aria-disabled");
      submitter2.removeEventListener("click", cancelEvent);
    }
  },
  disabled: {
    beforeSubmit: (submitter2) => submitter2.disabled = true,
    afterSubmit: (submitter2) => submitter2.disabled = false
  }
};

class Config {
  #submitter = null;
  constructor(config) {
    Object.assign(this, config);
  }
  get submitter() {
    return this.#submitter;
  }
  set submitter(value) {
    this.#submitter = submitter[value] || value;
  }
}
var forms = new Config({
  mode: "on",
  submitter: "disabled"
});
var config = {
  drive,
  forms
};
function expandURL(locatable) {
  return new URL(locatable.toString(), document.baseURI);
}
function getAnchor(url) {
  let anchorMatch;
  if (url.hash) {
    return url.hash.slice(1);
  } else if (anchorMatch = url.href.match(/#(.*)$/)) {
    return anchorMatch[1];
  }
}
function getAction$1(form, submitter2) {
  const action = submitter2?.getAttribute("formaction") || form.getAttribute("action") || form.action;
  return expandURL(action);
}
function getExtension(url) {
  return (getLastPathComponent(url).match(/\.[^.]*$/) || [])[0] || "";
}
function isPrefixedBy(baseURL, url) {
  const prefix = addTrailingSlash(url.origin + url.pathname);
  return addTrailingSlash(baseURL.href) === prefix || baseURL.href.startsWith(prefix);
}
function locationIsVisitable(location2, rootLocation) {
  return isPrefixedBy(location2, rootLocation) && !config.drive.unvisitableExtensions.has(getExtension(location2));
}
function getLocationForLink(link) {
  return expandURL(link.getAttribute("href") || "");
}
function getRequestURL(url) {
  const anchor = getAnchor(url);
  return anchor != null ? url.href.slice(0, -(anchor.length + 1)) : url.href;
}
function toCacheKey(url) {
  return getRequestURL(url);
}
function urlsAreEqual(left, right) {
  return expandURL(left).href == expandURL(right).href;
}
function getPathComponents(url) {
  return url.pathname.split("/").slice(1);
}
function getLastPathComponent(url) {
  return getPathComponents(url).slice(-1)[0];
}
function addTrailingSlash(value) {
  return value.endsWith("/") ? value : value + "/";
}

class FetchResponse {
  constructor(response) {
    this.response = response;
  }
  get succeeded() {
    return this.response.ok;
  }
  get failed() {
    return !this.succeeded;
  }
  get clientError() {
    return this.statusCode >= 400 && this.statusCode <= 499;
  }
  get serverError() {
    return this.statusCode >= 500 && this.statusCode <= 599;
  }
  get redirected() {
    return this.response.redirected;
  }
  get location() {
    return expandURL(this.response.url);
  }
  get isHTML() {
    return this.contentType && this.contentType.match(/^(?:text\/([^\s;,]+\b)?html|application\/xhtml\+xml)\b/);
  }
  get statusCode() {
    return this.response.status;
  }
  get contentType() {
    return this.header("Content-Type");
  }
  get responseText() {
    return this.response.clone().text();
  }
  get responseHTML() {
    if (this.isHTML) {
      return this.response.clone().text();
    } else {
      return Promise.resolve(undefined);
    }
  }
  header(name) {
    return this.response.headers.get(name);
  }
}

class LimitedSet extends Set {
  constructor(maxSize) {
    super();
    this.maxSize = maxSize;
  }
  add(value) {
    if (this.size >= this.maxSize) {
      const iterator = this.values();
      const oldestValue = iterator.next().value;
      this.delete(oldestValue);
    }
    super.add(value);
  }
}
var recentRequests = new LimitedSet(20);
function fetchWithTurboHeaders(url, options = {}) {
  const modifiedHeaders = new Headers(options.headers || {});
  const requestUID = uuid();
  recentRequests.add(requestUID);
  modifiedHeaders.append("X-Turbo-Request-Id", requestUID);
  return window.fetch(url, {
    ...options,
    headers: modifiedHeaders
  });
}
function fetchMethodFromString(method) {
  switch (method.toLowerCase()) {
    case "get":
      return FetchMethod.get;
    case "post":
      return FetchMethod.post;
    case "put":
      return FetchMethod.put;
    case "patch":
      return FetchMethod.patch;
    case "delete":
      return FetchMethod.delete;
  }
}
var FetchMethod = {
  get: "get",
  post: "post",
  put: "put",
  patch: "patch",
  delete: "delete"
};
function fetchEnctypeFromString(encoding) {
  switch (encoding.toLowerCase()) {
    case FetchEnctype.multipart:
      return FetchEnctype.multipart;
    case FetchEnctype.plain:
      return FetchEnctype.plain;
    default:
      return FetchEnctype.urlEncoded;
  }
}
var FetchEnctype = {
  urlEncoded: "application/x-www-form-urlencoded",
  multipart: "multipart/form-data",
  plain: "text/plain"
};

class FetchRequest {
  abortController = new AbortController;
  #resolveRequestPromise = (_value) => {
  };
  constructor(delegate, method, location2, requestBody = new URLSearchParams, target = null, enctype = FetchEnctype.urlEncoded) {
    const [url, body] = buildResourceAndBody(expandURL(location2), method, requestBody, enctype);
    this.delegate = delegate;
    this.url = url;
    this.target = target;
    this.fetchOptions = {
      credentials: "same-origin",
      redirect: "follow",
      method: method.toUpperCase(),
      headers: { ...this.defaultHeaders },
      body,
      signal: this.abortSignal,
      referrer: this.delegate.referrer?.href
    };
    this.enctype = enctype;
  }
  get method() {
    return this.fetchOptions.method;
  }
  set method(value) {
    const fetchBody = this.isSafe ? this.url.searchParams : this.fetchOptions.body || new FormData;
    const fetchMethod = fetchMethodFromString(value) || FetchMethod.get;
    this.url.search = "";
    const [url, body] = buildResourceAndBody(this.url, fetchMethod, fetchBody, this.enctype);
    this.url = url;
    this.fetchOptions.body = body;
    this.fetchOptions.method = fetchMethod.toUpperCase();
  }
  get headers() {
    return this.fetchOptions.headers;
  }
  set headers(value) {
    this.fetchOptions.headers = value;
  }
  get body() {
    if (this.isSafe) {
      return this.url.searchParams;
    } else {
      return this.fetchOptions.body;
    }
  }
  set body(value) {
    this.fetchOptions.body = value;
  }
  get location() {
    return this.url;
  }
  get params() {
    return this.url.searchParams;
  }
  get entries() {
    return this.body ? Array.from(this.body.entries()) : [];
  }
  cancel() {
    this.abortController.abort();
  }
  async perform() {
    const { fetchOptions } = this;
    this.delegate.prepareRequest(this);
    const event = await this.#allowRequestToBeIntercepted(fetchOptions);
    try {
      this.delegate.requestStarted(this);
      if (event.detail.fetchRequest) {
        this.response = event.detail.fetchRequest.response;
      } else {
        this.response = fetchWithTurboHeaders(this.url.href, fetchOptions);
      }
      const response = await this.response;
      return await this.receive(response);
    } catch (error) {
      if (error.name !== "AbortError") {
        if (this.#willDelegateErrorHandling(error)) {
          this.delegate.requestErrored(this, error);
        }
        throw error;
      }
    } finally {
      this.delegate.requestFinished(this);
    }
  }
  async receive(response) {
    const fetchResponse = new FetchResponse(response);
    const event = dispatch("turbo:before-fetch-response", {
      cancelable: true,
      detail: { fetchResponse },
      target: this.target
    });
    if (event.defaultPrevented) {
      this.delegate.requestPreventedHandlingResponse(this, fetchResponse);
    } else if (fetchResponse.succeeded) {
      this.delegate.requestSucceededWithResponse(this, fetchResponse);
    } else {
      this.delegate.requestFailedWithResponse(this, fetchResponse);
    }
    return fetchResponse;
  }
  get defaultHeaders() {
    return {
      Accept: "text/html, application/xhtml+xml"
    };
  }
  get isSafe() {
    return isSafe(this.method);
  }
  get abortSignal() {
    return this.abortController.signal;
  }
  acceptResponseType(mimeType) {
    this.headers["Accept"] = [mimeType, this.headers["Accept"]].join(", ");
  }
  async#allowRequestToBeIntercepted(fetchOptions) {
    const requestInterception = new Promise((resolve) => this.#resolveRequestPromise = resolve);
    const event = dispatch("turbo:before-fetch-request", {
      cancelable: true,
      detail: {
        fetchOptions,
        url: this.url,
        resume: this.#resolveRequestPromise
      },
      target: this.target
    });
    this.url = event.detail.url;
    if (event.defaultPrevented)
      await requestInterception;
    return event;
  }
  #willDelegateErrorHandling(error) {
    const event = dispatch("turbo:fetch-request-error", {
      target: this.target,
      cancelable: true,
      detail: { request: this, error }
    });
    return !event.defaultPrevented;
  }
}
function isSafe(fetchMethod) {
  return fetchMethodFromString(fetchMethod) == FetchMethod.get;
}
function buildResourceAndBody(resource, method, requestBody, enctype) {
  const searchParams = Array.from(requestBody).length > 0 ? new URLSearchParams(entriesExcludingFiles(requestBody)) : resource.searchParams;
  if (isSafe(method)) {
    return [mergeIntoURLSearchParams(resource, searchParams), null];
  } else if (enctype == FetchEnctype.urlEncoded) {
    return [resource, searchParams];
  } else {
    return [resource, requestBody];
  }
}
function entriesExcludingFiles(requestBody) {
  const entries = [];
  for (const [name, value] of requestBody) {
    if (value instanceof File)
      continue;
    else
      entries.push([name, value]);
  }
  return entries;
}
function mergeIntoURLSearchParams(url, requestBody) {
  const searchParams = new URLSearchParams(entriesExcludingFiles(requestBody));
  url.search = searchParams.toString();
  return url;
}

class AppearanceObserver {
  started = false;
  constructor(delegate, element) {
    this.delegate = delegate;
    this.element = element;
    this.intersectionObserver = new IntersectionObserver(this.intersect);
  }
  start() {
    if (!this.started) {
      this.started = true;
      this.intersectionObserver.observe(this.element);
    }
  }
  stop() {
    if (this.started) {
      this.started = false;
      this.intersectionObserver.unobserve(this.element);
    }
  }
  intersect = (entries) => {
    const lastEntry = entries.slice(-1)[0];
    if (lastEntry?.isIntersecting) {
      this.delegate.elementAppearedInViewport(this.element);
    }
  };
}

class StreamMessage {
  static contentType = "text/vnd.turbo-stream.html";
  static wrap(message) {
    if (typeof message == "string") {
      return new this(createDocumentFragment(message));
    } else {
      return message;
    }
  }
  constructor(fragment) {
    this.fragment = importStreamElements(fragment);
  }
}
function importStreamElements(fragment) {
  for (const element of fragment.querySelectorAll("turbo-stream")) {
    const streamElement = document.importNode(element, true);
    for (const inertScriptElement of streamElement.templateElement.content.querySelectorAll("script")) {
      inertScriptElement.replaceWith(activateScriptElement(inertScriptElement));
    }
    element.replaceWith(streamElement);
  }
  return fragment;
}
var identity = (key) => key;

class LRUCache {
  keys = [];
  entries = {};
  #toCacheKey;
  constructor(size, toCacheKey2 = identity) {
    this.size = size;
    this.#toCacheKey = toCacheKey2;
  }
  has(key) {
    return this.#toCacheKey(key) in this.entries;
  }
  get(key) {
    if (this.has(key)) {
      const entry = this.read(key);
      this.touch(key);
      return entry;
    }
  }
  put(key, entry) {
    this.write(key, entry);
    this.touch(key);
    return entry;
  }
  clear() {
    for (const key of Object.keys(this.entries)) {
      this.evict(key);
    }
  }
  read(key) {
    return this.entries[this.#toCacheKey(key)];
  }
  write(key, entry) {
    this.entries[this.#toCacheKey(key)] = entry;
  }
  touch(key) {
    key = this.#toCacheKey(key);
    const index = this.keys.indexOf(key);
    if (index > -1)
      this.keys.splice(index, 1);
    this.keys.unshift(key);
    this.trim();
  }
  trim() {
    for (const key of this.keys.splice(this.size)) {
      this.evict(key);
    }
  }
  evict(key) {
    delete this.entries[key];
  }
}
var PREFETCH_DELAY = 100;

class PrefetchCache extends LRUCache {
  #prefetchTimeout = null;
  #maxAges = {};
  constructor(size = 1, prefetchDelay = PREFETCH_DELAY) {
    super(size, toCacheKey);
    this.prefetchDelay = prefetchDelay;
  }
  putLater(url, request, ttl) {
    this.#prefetchTimeout = setTimeout(() => {
      request.perform();
      this.put(url, request, ttl);
      this.#prefetchTimeout = null;
    }, this.prefetchDelay);
  }
  put(url, request, ttl = cacheTtl) {
    super.put(url, request);
    this.#maxAges[toCacheKey(url)] = new Date(new Date().getTime() + ttl);
  }
  clear() {
    super.clear();
    if (this.#prefetchTimeout)
      clearTimeout(this.#prefetchTimeout);
  }
  evict(key) {
    super.evict(key);
    delete this.#maxAges[key];
  }
  has(key) {
    if (super.has(key)) {
      const maxAge = this.#maxAges[toCacheKey(key)];
      return maxAge && maxAge > Date.now();
    } else {
      return false;
    }
  }
}
var cacheTtl = 10 * 1000;
var prefetchCache = new PrefetchCache;
var FormSubmissionState = {
  initialized: "initialized",
  requesting: "requesting",
  waiting: "waiting",
  receiving: "receiving",
  stopping: "stopping",
  stopped: "stopped"
};

class FormSubmission {
  state = FormSubmissionState.initialized;
  static confirmMethod(message) {
    return Promise.resolve(confirm(message));
  }
  constructor(delegate, formElement, submitter2, mustRedirect = false) {
    const method = getMethod(formElement, submitter2);
    const action = getAction(getFormAction(formElement, submitter2), method);
    const body = buildFormData(formElement, submitter2);
    const enctype = getEnctype(formElement, submitter2);
    this.delegate = delegate;
    this.formElement = formElement;
    this.submitter = submitter2;
    this.fetchRequest = new FetchRequest(this, method, action, body, formElement, enctype);
    this.mustRedirect = mustRedirect;
  }
  get method() {
    return this.fetchRequest.method;
  }
  set method(value) {
    this.fetchRequest.method = value;
  }
  get action() {
    return this.fetchRequest.url.toString();
  }
  set action(value) {
    this.fetchRequest.url = expandURL(value);
  }
  get body() {
    return this.fetchRequest.body;
  }
  get enctype() {
    return this.fetchRequest.enctype;
  }
  get isSafe() {
    return this.fetchRequest.isSafe;
  }
  get location() {
    return this.fetchRequest.url;
  }
  async start() {
    const { initialized, requesting } = FormSubmissionState;
    const confirmationMessage = getAttribute("data-turbo-confirm", this.submitter, this.formElement);
    if (typeof confirmationMessage === "string") {
      const confirmMethod = typeof config.forms.confirm === "function" ? config.forms.confirm : FormSubmission.confirmMethod;
      const answer = await confirmMethod(confirmationMessage, this.formElement, this.submitter);
      if (!answer) {
        return;
      }
    }
    if (this.state == initialized) {
      this.state = requesting;
      return this.fetchRequest.perform();
    }
  }
  stop() {
    const { stopping, stopped } = FormSubmissionState;
    if (this.state != stopping && this.state != stopped) {
      this.state = stopping;
      this.fetchRequest.cancel();
      return true;
    }
  }
  prepareRequest(request) {
    if (!request.isSafe) {
      const token = getCookieValue(getMetaContent("csrf-param")) || getMetaContent("csrf-token");
      if (token) {
        request.headers["X-CSRF-Token"] = token;
      }
    }
    if (this.requestAcceptsTurboStreamResponse(request)) {
      request.acceptResponseType(StreamMessage.contentType);
    }
  }
  requestStarted(_request) {
    this.state = FormSubmissionState.waiting;
    if (this.submitter)
      config.forms.submitter.beforeSubmit(this.submitter);
    this.setSubmitsWith();
    markAsBusy(this.formElement);
    dispatch("turbo:submit-start", {
      target: this.formElement,
      detail: { formSubmission: this }
    });
    this.delegate.formSubmissionStarted(this);
  }
  requestPreventedHandlingResponse(request, response) {
    prefetchCache.clear();
    this.result = { success: response.succeeded, fetchResponse: response };
  }
  requestSucceededWithResponse(request, response) {
    if (response.clientError || response.serverError) {
      this.delegate.formSubmissionFailedWithResponse(this, response);
      return;
    }
    prefetchCache.clear();
    if (this.requestMustRedirect(request) && responseSucceededWithoutRedirect(response)) {
      const error = new Error("Form responses must redirect to another location");
      this.delegate.formSubmissionErrored(this, error);
    } else {
      this.state = FormSubmissionState.receiving;
      this.result = { success: true, fetchResponse: response };
      this.delegate.formSubmissionSucceededWithResponse(this, response);
    }
  }
  requestFailedWithResponse(request, response) {
    this.result = { success: false, fetchResponse: response };
    this.delegate.formSubmissionFailedWithResponse(this, response);
  }
  requestErrored(request, error) {
    this.result = { success: false, error };
    this.delegate.formSubmissionErrored(this, error);
  }
  requestFinished(_request) {
    this.state = FormSubmissionState.stopped;
    if (this.submitter)
      config.forms.submitter.afterSubmit(this.submitter);
    this.resetSubmitterText();
    clearBusyState(this.formElement);
    dispatch("turbo:submit-end", {
      target: this.formElement,
      detail: { formSubmission: this, ...this.result }
    });
    this.delegate.formSubmissionFinished(this);
  }
  setSubmitsWith() {
    if (!this.submitter || !this.submitsWith)
      return;
    if (this.submitter.matches("button")) {
      this.originalSubmitText = this.submitter.innerHTML;
      this.submitter.innerHTML = this.submitsWith;
    } else if (this.submitter.matches("input")) {
      const input = this.submitter;
      this.originalSubmitText = input.value;
      input.value = this.submitsWith;
    }
  }
  resetSubmitterText() {
    if (!this.submitter || !this.originalSubmitText)
      return;
    if (this.submitter.matches("button")) {
      this.submitter.innerHTML = this.originalSubmitText;
    } else if (this.submitter.matches("input")) {
      const input = this.submitter;
      input.value = this.originalSubmitText;
    }
  }
  requestMustRedirect(request) {
    return !request.isSafe && this.mustRedirect;
  }
  requestAcceptsTurboStreamResponse(request) {
    return !request.isSafe || hasAttribute("data-turbo-stream", this.submitter, this.formElement);
  }
  get submitsWith() {
    return this.submitter?.getAttribute("data-turbo-submits-with");
  }
}
function buildFormData(formElement, submitter2) {
  const formData = new FormData(formElement);
  const name = submitter2?.getAttribute("name");
  const value = submitter2?.getAttribute("value");
  if (name) {
    formData.append(name, value || "");
  }
  return formData;
}
function getCookieValue(cookieName) {
  if (cookieName != null) {
    const cookies = document.cookie ? document.cookie.split("; ") : [];
    const cookie = cookies.find((cookie2) => cookie2.startsWith(cookieName));
    if (cookie) {
      const value = cookie.split("=").slice(1).join("=");
      return value ? decodeURIComponent(value) : undefined;
    }
  }
}
function responseSucceededWithoutRedirect(response) {
  return response.statusCode == 200 && !response.redirected;
}
function getFormAction(formElement, submitter2) {
  const formElementAction = typeof formElement.action === "string" ? formElement.action : null;
  if (submitter2?.hasAttribute("formaction")) {
    return submitter2.getAttribute("formaction") || "";
  } else {
    return formElement.getAttribute("action") || formElementAction || "";
  }
}
function getAction(formAction, fetchMethod) {
  const action = expandURL(formAction);
  if (isSafe(fetchMethod)) {
    action.search = "";
  }
  return action;
}
function getMethod(formElement, submitter2) {
  const method = submitter2?.getAttribute("formmethod") || formElement.getAttribute("method") || "";
  return fetchMethodFromString(method.toLowerCase()) || FetchMethod.get;
}
function getEnctype(formElement, submitter2) {
  return fetchEnctypeFromString(submitter2?.getAttribute("formenctype") || formElement.enctype);
}

class Snapshot {
  constructor(element) {
    this.element = element;
  }
  get activeElement() {
    return this.element.ownerDocument.activeElement;
  }
  get children() {
    return [...this.element.children];
  }
  hasAnchor(anchor) {
    return this.getElementForAnchor(anchor) != null;
  }
  getElementForAnchor(anchor) {
    return anchor ? this.element.querySelector(`[id='${anchor}'], a[name='${anchor}']`) : null;
  }
  get isConnected() {
    return this.element.isConnected;
  }
  get firstAutofocusableElement() {
    return queryAutofocusableElement(this.element);
  }
  get permanentElements() {
    return queryPermanentElementsAll(this.element);
  }
  getPermanentElementById(id) {
    return getPermanentElementById(this.element, id);
  }
  getPermanentElementMapForSnapshot(snapshot) {
    const permanentElementMap = {};
    for (const currentPermanentElement of this.permanentElements) {
      const { id } = currentPermanentElement;
      const newPermanentElement = snapshot.getPermanentElementById(id);
      if (newPermanentElement) {
        permanentElementMap[id] = [currentPermanentElement, newPermanentElement];
      }
    }
    return permanentElementMap;
  }
}
function getPermanentElementById(node, id) {
  return node.querySelector(`#${id}[data-turbo-permanent]`);
}
function queryPermanentElementsAll(node) {
  return node.querySelectorAll("[id][data-turbo-permanent]");
}

class FormSubmitObserver {
  started = false;
  constructor(delegate, eventTarget) {
    this.delegate = delegate;
    this.eventTarget = eventTarget;
  }
  start() {
    if (!this.started) {
      this.eventTarget.addEventListener("submit", this.submitCaptured, true);
      this.started = true;
    }
  }
  stop() {
    if (this.started) {
      this.eventTarget.removeEventListener("submit", this.submitCaptured, true);
      this.started = false;
    }
  }
  submitCaptured = () => {
    this.eventTarget.removeEventListener("submit", this.submitBubbled, false);
    this.eventTarget.addEventListener("submit", this.submitBubbled, false);
  };
  submitBubbled = (event) => {
    if (!event.defaultPrevented) {
      const form = event.target instanceof HTMLFormElement ? event.target : undefined;
      const submitter2 = event.submitter || undefined;
      if (form && submissionDoesNotDismissDialog(form, submitter2) && submissionDoesNotTargetIFrame(form, submitter2) && this.delegate.willSubmitForm(form, submitter2)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        this.delegate.formSubmitted(form, submitter2);
      }
    }
  };
}
function submissionDoesNotDismissDialog(form, submitter2) {
  const method = submitter2?.getAttribute("formmethod") || form.getAttribute("method");
  return method != "dialog";
}
function submissionDoesNotTargetIFrame(form, submitter2) {
  const target = submitter2?.getAttribute("formtarget") || form.getAttribute("target");
  return doesNotTargetIFrame(target);
}

class View {
  #resolveRenderPromise = (_value) => {
  };
  #resolveInterceptionPromise = (_value) => {
  };
  constructor(delegate, element) {
    this.delegate = delegate;
    this.element = element;
  }
  scrollToAnchor(anchor) {
    const element = this.snapshot.getElementForAnchor(anchor);
    if (element) {
      this.focusElement(element);
      this.scrollToElement(element);
    } else {
      this.scrollToPosition({ x: 0, y: 0 });
    }
  }
  scrollToAnchorFromLocation(location2) {
    this.scrollToAnchor(getAnchor(location2));
  }
  scrollToElement(element) {
    element.scrollIntoView();
  }
  focusElement(element) {
    if (element instanceof HTMLElement) {
      if (element.hasAttribute("tabindex")) {
        element.focus();
      } else {
        element.setAttribute("tabindex", "-1");
        element.focus();
        element.removeAttribute("tabindex");
      }
    }
  }
  scrollToPosition({ x, y }) {
    this.scrollRoot.scrollTo(x, y);
  }
  scrollToTop() {
    this.scrollToPosition({ x: 0, y: 0 });
  }
  get scrollRoot() {
    return window;
  }
  async render(renderer) {
    const { isPreview, shouldRender, willRender, newSnapshot: snapshot } = renderer;
    const shouldInvalidate = willRender;
    if (shouldRender) {
      try {
        this.renderPromise = new Promise((resolve) => this.#resolveRenderPromise = resolve);
        this.renderer = renderer;
        await this.prepareToRenderSnapshot(renderer);
        const renderInterception = new Promise((resolve) => this.#resolveInterceptionPromise = resolve);
        const options = { resume: this.#resolveInterceptionPromise, render: this.renderer.renderElement, renderMethod: this.renderer.renderMethod };
        const immediateRender = this.delegate.allowsImmediateRender(snapshot, options);
        if (!immediateRender)
          await renderInterception;
        await this.renderSnapshot(renderer);
        this.delegate.viewRenderedSnapshot(snapshot, isPreview, this.renderer.renderMethod);
        this.delegate.preloadOnLoadLinksForView(this.element);
        this.finishRenderingSnapshot(renderer);
      } finally {
        delete this.renderer;
        this.#resolveRenderPromise(undefined);
        delete this.renderPromise;
      }
    } else if (shouldInvalidate) {
      this.invalidate(renderer.reloadReason);
    }
  }
  invalidate(reason) {
    this.delegate.viewInvalidated(reason);
  }
  async prepareToRenderSnapshot(renderer) {
    this.markAsPreview(renderer.isPreview);
    await renderer.prepareToRender();
  }
  markAsPreview(isPreview) {
    if (isPreview) {
      this.element.setAttribute("data-turbo-preview", "");
    } else {
      this.element.removeAttribute("data-turbo-preview");
    }
  }
  markVisitDirection(direction) {
    this.element.setAttribute("data-turbo-visit-direction", direction);
  }
  unmarkVisitDirection() {
    this.element.removeAttribute("data-turbo-visit-direction");
  }
  async renderSnapshot(renderer) {
    await renderer.render();
  }
  finishRenderingSnapshot(renderer) {
    renderer.finishRendering();
  }
}

class FrameView extends View {
  missing() {
    this.element.innerHTML = `<strong class="turbo-frame-error">Content missing</strong>`;
  }
  get snapshot() {
    return new Snapshot(this.element);
  }
}

class LinkInterceptor {
  constructor(delegate, element) {
    this.delegate = delegate;
    this.element = element;
  }
  start() {
    this.element.addEventListener("click", this.clickBubbled);
    document.addEventListener("turbo:click", this.linkClicked);
    document.addEventListener("turbo:before-visit", this.willVisit);
  }
  stop() {
    this.element.removeEventListener("click", this.clickBubbled);
    document.removeEventListener("turbo:click", this.linkClicked);
    document.removeEventListener("turbo:before-visit", this.willVisit);
  }
  clickBubbled = (event) => {
    if (this.clickEventIsSignificant(event)) {
      this.clickEvent = event;
    } else {
      delete this.clickEvent;
    }
  };
  linkClicked = (event) => {
    if (this.clickEvent && this.clickEventIsSignificant(event)) {
      if (this.delegate.shouldInterceptLinkClick(event.target, event.detail.url, event.detail.originalEvent)) {
        this.clickEvent.preventDefault();
        event.preventDefault();
        this.delegate.linkClickIntercepted(event.target, event.detail.url, event.detail.originalEvent);
      }
    }
    delete this.clickEvent;
  };
  willVisit = (_event) => {
    delete this.clickEvent;
  };
  clickEventIsSignificant(event) {
    const target = event.composed ? event.target?.parentElement : event.target;
    const element = findLinkFromClickTarget(target) || target;
    return element instanceof Element && element.closest("turbo-frame, html") == this.element;
  }
}

class LinkClickObserver {
  started = false;
  constructor(delegate, eventTarget) {
    this.delegate = delegate;
    this.eventTarget = eventTarget;
  }
  start() {
    if (!this.started) {
      this.eventTarget.addEventListener("click", this.clickCaptured, true);
      this.started = true;
    }
  }
  stop() {
    if (this.started) {
      this.eventTarget.removeEventListener("click", this.clickCaptured, true);
      this.started = false;
    }
  }
  clickCaptured = () => {
    this.eventTarget.removeEventListener("click", this.clickBubbled, false);
    this.eventTarget.addEventListener("click", this.clickBubbled, false);
  };
  clickBubbled = (event) => {
    if (event instanceof MouseEvent && this.clickEventIsSignificant(event)) {
      const target = event.composedPath && event.composedPath()[0] || event.target;
      const link = findLinkFromClickTarget(target);
      if (link && doesNotTargetIFrame(link.target)) {
        const location2 = getLocationForLink(link);
        if (this.delegate.willFollowLinkToLocation(link, location2, event)) {
          event.preventDefault();
          this.delegate.followedLinkToLocation(link, location2);
        }
      }
    }
  };
  clickEventIsSignificant(event) {
    return !(event.target && event.target.isContentEditable || event.defaultPrevented || event.which > 1 || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey);
  }
}

class FormLinkClickObserver {
  constructor(delegate, element) {
    this.delegate = delegate;
    this.linkInterceptor = new LinkClickObserver(this, element);
  }
  start() {
    this.linkInterceptor.start();
  }
  stop() {
    this.linkInterceptor.stop();
  }
  canPrefetchRequestToLocation(link, location2) {
    return false;
  }
  prefetchAndCacheRequestToLocation(link, location2) {
    return;
  }
  willFollowLinkToLocation(link, location2, originalEvent) {
    return this.delegate.willSubmitFormLinkToLocation(link, location2, originalEvent) && (link.hasAttribute("data-turbo-method") || link.hasAttribute("data-turbo-stream"));
  }
  followedLinkToLocation(link, location2) {
    const form = document.createElement("form");
    const type = "hidden";
    for (const [name, value] of location2.searchParams) {
      form.append(Object.assign(document.createElement("input"), { type, name, value }));
    }
    const action = Object.assign(location2, { search: "" });
    form.setAttribute("data-turbo", "true");
    form.setAttribute("action", action.href);
    form.setAttribute("hidden", "");
    const method = link.getAttribute("data-turbo-method");
    if (method)
      form.setAttribute("method", method);
    const turboFrame = link.getAttribute("data-turbo-frame");
    if (turboFrame)
      form.setAttribute("data-turbo-frame", turboFrame);
    const turboAction = getVisitAction(link);
    if (turboAction)
      form.setAttribute("data-turbo-action", turboAction);
    const turboConfirm = link.getAttribute("data-turbo-confirm");
    if (turboConfirm)
      form.setAttribute("data-turbo-confirm", turboConfirm);
    const turboStream = link.hasAttribute("data-turbo-stream");
    if (turboStream)
      form.setAttribute("data-turbo-stream", "");
    this.delegate.submittedFormLinkToLocation(link, location2, form);
    document.body.appendChild(form);
    form.addEventListener("turbo:submit-end", () => form.remove(), { once: true });
    requestAnimationFrame(() => form.requestSubmit());
  }
}

class Bardo {
  static async preservingPermanentElements(delegate, permanentElementMap, callback) {
    const bardo = new this(delegate, permanentElementMap);
    bardo.enter();
    await callback();
    bardo.leave();
  }
  constructor(delegate, permanentElementMap) {
    this.delegate = delegate;
    this.permanentElementMap = permanentElementMap;
  }
  enter() {
    for (const id in this.permanentElementMap) {
      const [currentPermanentElement, newPermanentElement] = this.permanentElementMap[id];
      this.delegate.enteringBardo(currentPermanentElement, newPermanentElement);
      this.replaceNewPermanentElementWithPlaceholder(newPermanentElement);
    }
  }
  leave() {
    for (const id in this.permanentElementMap) {
      const [currentPermanentElement] = this.permanentElementMap[id];
      this.replaceCurrentPermanentElementWithClone(currentPermanentElement);
      this.replacePlaceholderWithPermanentElement(currentPermanentElement);
      this.delegate.leavingBardo(currentPermanentElement);
    }
  }
  replaceNewPermanentElementWithPlaceholder(permanentElement) {
    const placeholder = createPlaceholderForPermanentElement(permanentElement);
    permanentElement.replaceWith(placeholder);
  }
  replaceCurrentPermanentElementWithClone(permanentElement) {
    const clone = permanentElement.cloneNode(true);
    permanentElement.replaceWith(clone);
  }
  replacePlaceholderWithPermanentElement(permanentElement) {
    const placeholder = this.getPlaceholderById(permanentElement.id);
    placeholder?.replaceWith(permanentElement);
  }
  getPlaceholderById(id) {
    return this.placeholders.find((element) => element.content == id);
  }
  get placeholders() {
    return [...document.querySelectorAll("meta[name=turbo-permanent-placeholder][content]")];
  }
}
function createPlaceholderForPermanentElement(permanentElement) {
  const element = document.createElement("meta");
  element.setAttribute("name", "turbo-permanent-placeholder");
  element.setAttribute("content", permanentElement.id);
  return element;
}

class Renderer {
  #activeElement = null;
  static renderElement(currentElement, newElement) {
  }
  constructor(currentSnapshot, newSnapshot, isPreview, willRender = true) {
    this.currentSnapshot = currentSnapshot;
    this.newSnapshot = newSnapshot;
    this.isPreview = isPreview;
    this.willRender = willRender;
    this.renderElement = this.constructor.renderElement;
    this.promise = new Promise((resolve, reject) => this.resolvingFunctions = { resolve, reject });
  }
  get shouldRender() {
    return true;
  }
  get shouldAutofocus() {
    return true;
  }
  get reloadReason() {
    return;
  }
  prepareToRender() {
    return;
  }
  render() {
  }
  finishRendering() {
    if (this.resolvingFunctions) {
      this.resolvingFunctions.resolve();
      delete this.resolvingFunctions;
    }
  }
  async preservingPermanentElements(callback) {
    await Bardo.preservingPermanentElements(this, this.permanentElementMap, callback);
  }
  focusFirstAutofocusableElement() {
    if (this.shouldAutofocus) {
      const element = this.connectedSnapshot.firstAutofocusableElement;
      if (element) {
        element.focus();
      }
    }
  }
  enteringBardo(currentPermanentElement) {
    if (this.#activeElement)
      return;
    if (currentPermanentElement.contains(this.currentSnapshot.activeElement)) {
      this.#activeElement = this.currentSnapshot.activeElement;
    }
  }
  leavingBardo(currentPermanentElement) {
    if (currentPermanentElement.contains(this.#activeElement) && this.#activeElement instanceof HTMLElement) {
      this.#activeElement.focus();
      this.#activeElement = null;
    }
  }
  get connectedSnapshot() {
    return this.newSnapshot.isConnected ? this.newSnapshot : this.currentSnapshot;
  }
  get currentElement() {
    return this.currentSnapshot.element;
  }
  get newElement() {
    return this.newSnapshot.element;
  }
  get permanentElementMap() {
    return this.currentSnapshot.getPermanentElementMapForSnapshot(this.newSnapshot);
  }
  get renderMethod() {
    return "replace";
  }
}

class FrameRenderer extends Renderer {
  static renderElement(currentElement, newElement) {
    const destinationRange = document.createRange();
    destinationRange.selectNodeContents(currentElement);
    destinationRange.deleteContents();
    const frameElement = newElement;
    const sourceRange = frameElement.ownerDocument?.createRange();
    if (sourceRange) {
      sourceRange.selectNodeContents(frameElement);
      currentElement.appendChild(sourceRange.extractContents());
    }
  }
  constructor(delegate, currentSnapshot, newSnapshot, renderElement, isPreview, willRender = true) {
    super(currentSnapshot, newSnapshot, renderElement, isPreview, willRender);
    this.delegate = delegate;
  }
  get shouldRender() {
    return true;
  }
  async render() {
    await nextRepaint();
    this.preservingPermanentElements(() => {
      this.loadFrameElement();
    });
    this.scrollFrameIntoView();
    await nextRepaint();
    this.focusFirstAutofocusableElement();
    await nextRepaint();
    this.activateScriptElements();
  }
  loadFrameElement() {
    this.delegate.willRenderFrame(this.currentElement, this.newElement);
    this.renderElement(this.currentElement, this.newElement);
  }
  scrollFrameIntoView() {
    if (this.currentElement.autoscroll || this.newElement.autoscroll) {
      const element = this.currentElement.firstElementChild;
      const block = readScrollLogicalPosition(this.currentElement.getAttribute("data-autoscroll-block"), "end");
      const behavior = readScrollBehavior(this.currentElement.getAttribute("data-autoscroll-behavior"), "auto");
      if (element) {
        element.scrollIntoView({ block, behavior });
        return true;
      }
    }
    return false;
  }
  activateScriptElements() {
    for (const inertScriptElement of this.newScriptElements) {
      const activatedScriptElement = activateScriptElement(inertScriptElement);
      inertScriptElement.replaceWith(activatedScriptElement);
    }
  }
  get newScriptElements() {
    return this.currentElement.querySelectorAll("script");
  }
}
function readScrollLogicalPosition(value, defaultValue) {
  if (value == "end" || value == "start" || value == "center" || value == "nearest") {
    return value;
  } else {
    return defaultValue;
  }
}
function readScrollBehavior(value, defaultValue) {
  if (value == "auto" || value == "smooth") {
    return value;
  } else {
    return defaultValue;
  }
}
var Idiomorph = function() {
  const noOp = () => {
  };
  const defaults = {
    morphStyle: "outerHTML",
    callbacks: {
      beforeNodeAdded: noOp,
      afterNodeAdded: noOp,
      beforeNodeMorphed: noOp,
      afterNodeMorphed: noOp,
      beforeNodeRemoved: noOp,
      afterNodeRemoved: noOp,
      beforeAttributeUpdated: noOp
    },
    head: {
      style: "merge",
      shouldPreserve: (elt) => elt.getAttribute("im-preserve") === "true",
      shouldReAppend: (elt) => elt.getAttribute("im-re-append") === "true",
      shouldRemove: noOp,
      afterHeadMorphed: noOp
    },
    restoreFocus: true
  };
  function morph(oldNode, newContent, config2 = {}) {
    oldNode = normalizeElement(oldNode);
    const newNode = normalizeParent(newContent);
    const ctx = createMorphContext(oldNode, newNode, config2);
    const morphedNodes = saveAndRestoreFocus(ctx, () => {
      return withHeadBlocking(ctx, oldNode, newNode, (ctx2) => {
        if (ctx2.morphStyle === "innerHTML") {
          morphChildren(ctx2, oldNode, newNode);
          return Array.from(oldNode.childNodes);
        } else {
          return morphOuterHTML(ctx2, oldNode, newNode);
        }
      });
    });
    ctx.pantry.remove();
    return morphedNodes;
  }
  function morphOuterHTML(ctx, oldNode, newNode) {
    const oldParent = normalizeParent(oldNode);
    morphChildren(ctx, oldParent, newNode, oldNode, oldNode.nextSibling);
    return Array.from(oldParent.childNodes);
  }
  function saveAndRestoreFocus(ctx, fn) {
    if (!ctx.config.restoreFocus)
      return fn();
    let activeElement = document.activeElement;
    if (!(activeElement instanceof HTMLInputElement || activeElement instanceof HTMLTextAreaElement)) {
      return fn();
    }
    const { id: activeElementId, selectionStart, selectionEnd } = activeElement;
    const results = fn();
    if (activeElementId && activeElementId !== document.activeElement?.getAttribute("id")) {
      activeElement = ctx.target.querySelector(`[id="${activeElementId}"]`);
      activeElement?.focus();
    }
    if (activeElement && !activeElement.selectionEnd && selectionEnd) {
      activeElement.setSelectionRange(selectionStart, selectionEnd);
    }
    return results;
  }
  const morphChildren = function() {
    function morphChildren2(ctx, oldParent, newParent, insertionPoint = null, endPoint = null) {
      if (oldParent instanceof HTMLTemplateElement && newParent instanceof HTMLTemplateElement) {
        oldParent = oldParent.content;
        newParent = newParent.content;
      }
      insertionPoint ||= oldParent.firstChild;
      for (const newChild of newParent.childNodes) {
        if (insertionPoint && insertionPoint != endPoint) {
          const bestMatch = findBestMatch(ctx, newChild, insertionPoint, endPoint);
          if (bestMatch) {
            if (bestMatch !== insertionPoint) {
              removeNodesBetween(ctx, insertionPoint, bestMatch);
            }
            morphNode(bestMatch, newChild, ctx);
            insertionPoint = bestMatch.nextSibling;
            continue;
          }
        }
        if (newChild instanceof Element) {
          const newChildId = newChild.getAttribute("id");
          if (ctx.persistentIds.has(newChildId)) {
            const movedChild = moveBeforeById(oldParent, newChildId, insertionPoint, ctx);
            morphNode(movedChild, newChild, ctx);
            insertionPoint = movedChild.nextSibling;
            continue;
          }
        }
        const insertedNode = createNode(oldParent, newChild, insertionPoint, ctx);
        if (insertedNode) {
          insertionPoint = insertedNode.nextSibling;
        }
      }
      while (insertionPoint && insertionPoint != endPoint) {
        const tempNode = insertionPoint;
        insertionPoint = insertionPoint.nextSibling;
        removeNode(ctx, tempNode);
      }
    }
    function createNode(oldParent, newChild, insertionPoint, ctx) {
      if (ctx.callbacks.beforeNodeAdded(newChild) === false)
        return null;
      if (ctx.idMap.has(newChild)) {
        const newEmptyChild = document.createElement(newChild.tagName);
        oldParent.insertBefore(newEmptyChild, insertionPoint);
        morphNode(newEmptyChild, newChild, ctx);
        ctx.callbacks.afterNodeAdded(newEmptyChild);
        return newEmptyChild;
      } else {
        const newClonedChild = document.importNode(newChild, true);
        oldParent.insertBefore(newClonedChild, insertionPoint);
        ctx.callbacks.afterNodeAdded(newClonedChild);
        return newClonedChild;
      }
    }
    const findBestMatch = function() {
      function findBestMatch2(ctx, node, startPoint, endPoint) {
        let softMatch = null;
        let nextSibling = node.nextSibling;
        let siblingSoftMatchCount = 0;
        let cursor = startPoint;
        while (cursor && cursor != endPoint) {
          if (isSoftMatch(cursor, node)) {
            if (isIdSetMatch(ctx, cursor, node)) {
              return cursor;
            }
            if (softMatch === null) {
              if (!ctx.idMap.has(cursor)) {
                softMatch = cursor;
              }
            }
          }
          if (softMatch === null && nextSibling && isSoftMatch(cursor, nextSibling)) {
            siblingSoftMatchCount++;
            nextSibling = nextSibling.nextSibling;
            if (siblingSoftMatchCount >= 2) {
              softMatch = undefined;
            }
          }
          if (ctx.activeElementAndParents.includes(cursor))
            break;
          cursor = cursor.nextSibling;
        }
        return softMatch || null;
      }
      function isIdSetMatch(ctx, oldNode, newNode) {
        let oldSet = ctx.idMap.get(oldNode);
        let newSet = ctx.idMap.get(newNode);
        if (!newSet || !oldSet)
          return false;
        for (const id of oldSet) {
          if (newSet.has(id)) {
            return true;
          }
        }
        return false;
      }
      function isSoftMatch(oldNode, newNode) {
        const oldElt = oldNode;
        const newElt = newNode;
        return oldElt.nodeType === newElt.nodeType && oldElt.tagName === newElt.tagName && (!oldElt.getAttribute?.("id") || oldElt.getAttribute?.("id") === newElt.getAttribute?.("id"));
      }
      return findBestMatch2;
    }();
    function removeNode(ctx, node) {
      if (ctx.idMap.has(node)) {
        moveBefore(ctx.pantry, node, null);
      } else {
        if (ctx.callbacks.beforeNodeRemoved(node) === false)
          return;
        node.parentNode?.removeChild(node);
        ctx.callbacks.afterNodeRemoved(node);
      }
    }
    function removeNodesBetween(ctx, startInclusive, endExclusive) {
      let cursor = startInclusive;
      while (cursor && cursor !== endExclusive) {
        let tempNode = cursor;
        cursor = cursor.nextSibling;
        removeNode(ctx, tempNode);
      }
      return cursor;
    }
    function moveBeforeById(parentNode, id, after, ctx) {
      const target = ctx.target.getAttribute?.("id") === id && ctx.target || ctx.target.querySelector(`[id="${id}"]`) || ctx.pantry.querySelector(`[id="${id}"]`);
      removeElementFromAncestorsIdMaps(target, ctx);
      moveBefore(parentNode, target, after);
      return target;
    }
    function removeElementFromAncestorsIdMaps(element, ctx) {
      const id = element.getAttribute("id");
      while (element = element.parentNode) {
        let idSet = ctx.idMap.get(element);
        if (idSet) {
          idSet.delete(id);
          if (!idSet.size) {
            ctx.idMap.delete(element);
          }
        }
      }
    }
    function moveBefore(parentNode, element, after) {
      if (parentNode.moveBefore) {
        try {
          parentNode.moveBefore(element, after);
        } catch (e) {
          parentNode.insertBefore(element, after);
        }
      } else {
        parentNode.insertBefore(element, after);
      }
    }
    return morphChildren2;
  }();
  const morphNode = function() {
    function morphNode2(oldNode, newContent, ctx) {
      if (ctx.ignoreActive && oldNode === document.activeElement) {
        return null;
      }
      if (ctx.callbacks.beforeNodeMorphed(oldNode, newContent) === false) {
        return oldNode;
      }
      if (oldNode instanceof HTMLHeadElement && ctx.head.ignore)
        ;
      else if (oldNode instanceof HTMLHeadElement && ctx.head.style !== "morph") {
        handleHeadElement(oldNode, newContent, ctx);
      } else {
        morphAttributes(oldNode, newContent, ctx);
        if (!ignoreValueOfActiveElement(oldNode, ctx)) {
          morphChildren(ctx, oldNode, newContent);
        }
      }
      ctx.callbacks.afterNodeMorphed(oldNode, newContent);
      return oldNode;
    }
    function morphAttributes(oldNode, newNode, ctx) {
      let type = newNode.nodeType;
      if (type === 1) {
        const oldElt = oldNode;
        const newElt = newNode;
        const oldAttributes = oldElt.attributes;
        const newAttributes = newElt.attributes;
        for (const newAttribute of newAttributes) {
          if (ignoreAttribute(newAttribute.name, oldElt, "update", ctx)) {
            continue;
          }
          if (oldElt.getAttribute(newAttribute.name) !== newAttribute.value) {
            oldElt.setAttribute(newAttribute.name, newAttribute.value);
          }
        }
        for (let i = oldAttributes.length - 1;0 <= i; i--) {
          const oldAttribute = oldAttributes[i];
          if (!oldAttribute)
            continue;
          if (!newElt.hasAttribute(oldAttribute.name)) {
            if (ignoreAttribute(oldAttribute.name, oldElt, "remove", ctx)) {
              continue;
            }
            oldElt.removeAttribute(oldAttribute.name);
          }
        }
        if (!ignoreValueOfActiveElement(oldElt, ctx)) {
          syncInputValue(oldElt, newElt, ctx);
        }
      }
      if (type === 8 || type === 3) {
        if (oldNode.nodeValue !== newNode.nodeValue) {
          oldNode.nodeValue = newNode.nodeValue;
        }
      }
    }
    function syncInputValue(oldElement, newElement, ctx) {
      if (oldElement instanceof HTMLInputElement && newElement instanceof HTMLInputElement && newElement.type !== "file") {
        let newValue = newElement.value;
        let oldValue = oldElement.value;
        syncBooleanAttribute(oldElement, newElement, "checked", ctx);
        syncBooleanAttribute(oldElement, newElement, "disabled", ctx);
        if (!newElement.hasAttribute("value")) {
          if (!ignoreAttribute("value", oldElement, "remove", ctx)) {
            oldElement.value = "";
            oldElement.removeAttribute("value");
          }
        } else if (oldValue !== newValue) {
          if (!ignoreAttribute("value", oldElement, "update", ctx)) {
            oldElement.setAttribute("value", newValue);
            oldElement.value = newValue;
          }
        }
      } else if (oldElement instanceof HTMLOptionElement && newElement instanceof HTMLOptionElement) {
        syncBooleanAttribute(oldElement, newElement, "selected", ctx);
      } else if (oldElement instanceof HTMLTextAreaElement && newElement instanceof HTMLTextAreaElement) {
        let newValue = newElement.value;
        let oldValue = oldElement.value;
        if (ignoreAttribute("value", oldElement, "update", ctx)) {
          return;
        }
        if (newValue !== oldValue) {
          oldElement.value = newValue;
        }
        if (oldElement.firstChild && oldElement.firstChild.nodeValue !== newValue) {
          oldElement.firstChild.nodeValue = newValue;
        }
      }
    }
    function syncBooleanAttribute(oldElement, newElement, attributeName, ctx) {
      const newLiveValue = newElement[attributeName], oldLiveValue = oldElement[attributeName];
      if (newLiveValue !== oldLiveValue) {
        const ignoreUpdate = ignoreAttribute(attributeName, oldElement, "update", ctx);
        if (!ignoreUpdate) {
          oldElement[attributeName] = newElement[attributeName];
        }
        if (newLiveValue) {
          if (!ignoreUpdate) {
            oldElement.setAttribute(attributeName, "");
          }
        } else {
          if (!ignoreAttribute(attributeName, oldElement, "remove", ctx)) {
            oldElement.removeAttribute(attributeName);
          }
        }
      }
    }
    function ignoreAttribute(attr, element, updateType, ctx) {
      if (attr === "value" && ctx.ignoreActiveValue && element === document.activeElement) {
        return true;
      }
      return ctx.callbacks.beforeAttributeUpdated(attr, element, updateType) === false;
    }
    function ignoreValueOfActiveElement(possibleActiveElement, ctx) {
      return !!ctx.ignoreActiveValue && possibleActiveElement === document.activeElement && possibleActiveElement !== document.body;
    }
    return morphNode2;
  }();
  function withHeadBlocking(ctx, oldNode, newNode, callback) {
    if (ctx.head.block) {
      const oldHead = oldNode.querySelector("head");
      const newHead = newNode.querySelector("head");
      if (oldHead && newHead) {
        const promises = handleHeadElement(oldHead, newHead, ctx);
        return Promise.all(promises).then(() => {
          const newCtx = Object.assign(ctx, {
            head: {
              block: false,
              ignore: true
            }
          });
          return callback(newCtx);
        });
      }
    }
    return callback(ctx);
  }
  function handleHeadElement(oldHead, newHead, ctx) {
    let added = [];
    let removed = [];
    let preserved = [];
    let nodesToAppend = [];
    let srcToNewHeadNodes = new Map;
    for (const newHeadChild of newHead.children) {
      srcToNewHeadNodes.set(newHeadChild.outerHTML, newHeadChild);
    }
    for (const currentHeadElt of oldHead.children) {
      let inNewContent = srcToNewHeadNodes.has(currentHeadElt.outerHTML);
      let isReAppended = ctx.head.shouldReAppend(currentHeadElt);
      let isPreserved = ctx.head.shouldPreserve(currentHeadElt);
      if (inNewContent || isPreserved) {
        if (isReAppended) {
          removed.push(currentHeadElt);
        } else {
          srcToNewHeadNodes.delete(currentHeadElt.outerHTML);
          preserved.push(currentHeadElt);
        }
      } else {
        if (ctx.head.style === "append") {
          if (isReAppended) {
            removed.push(currentHeadElt);
            nodesToAppend.push(currentHeadElt);
          }
        } else {
          if (ctx.head.shouldRemove(currentHeadElt) !== false) {
            removed.push(currentHeadElt);
          }
        }
      }
    }
    nodesToAppend.push(...srcToNewHeadNodes.values());
    let promises = [];
    for (const newNode of nodesToAppend) {
      let newElt = document.createRange().createContextualFragment(newNode.outerHTML).firstChild;
      if (ctx.callbacks.beforeNodeAdded(newElt) !== false) {
        if ("href" in newElt && newElt.href || "src" in newElt && newElt.src) {
          let resolve;
          let promise = new Promise(function(_resolve) {
            resolve = _resolve;
          });
          newElt.addEventListener("load", function() {
            resolve();
          });
          promises.push(promise);
        }
        oldHead.appendChild(newElt);
        ctx.callbacks.afterNodeAdded(newElt);
        added.push(newElt);
      }
    }
    for (const removedElement of removed) {
      if (ctx.callbacks.beforeNodeRemoved(removedElement) !== false) {
        oldHead.removeChild(removedElement);
        ctx.callbacks.afterNodeRemoved(removedElement);
      }
    }
    ctx.head.afterHeadMorphed(oldHead, {
      added,
      kept: preserved,
      removed
    });
    return promises;
  }
  const createMorphContext = function() {
    function createMorphContext2(oldNode, newContent, config2) {
      const { persistentIds, idMap } = createIdMaps(oldNode, newContent);
      const mergedConfig = mergeDefaults(config2);
      const morphStyle = mergedConfig.morphStyle || "outerHTML";
      if (!["innerHTML", "outerHTML"].includes(morphStyle)) {
        throw `Do not understand how to morph style ${morphStyle}`;
      }
      return {
        target: oldNode,
        newContent,
        config: mergedConfig,
        morphStyle,
        ignoreActive: mergedConfig.ignoreActive,
        ignoreActiveValue: mergedConfig.ignoreActiveValue,
        restoreFocus: mergedConfig.restoreFocus,
        idMap,
        persistentIds,
        pantry: createPantry(),
        activeElementAndParents: createActiveElementAndParents(oldNode),
        callbacks: mergedConfig.callbacks,
        head: mergedConfig.head
      };
    }
    function mergeDefaults(config2) {
      let finalConfig = Object.assign({}, defaults);
      Object.assign(finalConfig, config2);
      finalConfig.callbacks = Object.assign({}, defaults.callbacks, config2.callbacks);
      finalConfig.head = Object.assign({}, defaults.head, config2.head);
      return finalConfig;
    }
    function createPantry() {
      const pantry = document.createElement("div");
      pantry.hidden = true;
      document.body.insertAdjacentElement("afterend", pantry);
      return pantry;
    }
    function createActiveElementAndParents(oldNode) {
      let activeElementAndParents = [];
      let elt = document.activeElement;
      if (elt?.tagName !== "BODY" && oldNode.contains(elt)) {
        while (elt) {
          activeElementAndParents.push(elt);
          if (elt === oldNode)
            break;
          elt = elt.parentElement;
        }
      }
      return activeElementAndParents;
    }
    function findIdElements(root) {
      let elements = Array.from(root.querySelectorAll("[id]"));
      if (root.getAttribute?.("id")) {
        elements.push(root);
      }
      return elements;
    }
    function populateIdMapWithTree(idMap, persistentIds, root, elements) {
      for (const elt of elements) {
        const id = elt.getAttribute("id");
        if (persistentIds.has(id)) {
          let current = elt;
          while (current) {
            let idSet = idMap.get(current);
            if (idSet == null) {
              idSet = new Set;
              idMap.set(current, idSet);
            }
            idSet.add(id);
            if (current === root)
              break;
            current = current.parentElement;
          }
        }
      }
    }
    function createIdMaps(oldContent, newContent) {
      const oldIdElements = findIdElements(oldContent);
      const newIdElements = findIdElements(newContent);
      const persistentIds = createPersistentIds(oldIdElements, newIdElements);
      let idMap = new Map;
      populateIdMapWithTree(idMap, persistentIds, oldContent, oldIdElements);
      const newRoot = newContent.__idiomorphRoot || newContent;
      populateIdMapWithTree(idMap, persistentIds, newRoot, newIdElements);
      return { persistentIds, idMap };
    }
    function createPersistentIds(oldIdElements, newIdElements) {
      let duplicateIds = new Set;
      let oldIdTagNameMap = new Map;
      for (const { id, tagName } of oldIdElements) {
        if (oldIdTagNameMap.has(id)) {
          duplicateIds.add(id);
        } else {
          oldIdTagNameMap.set(id, tagName);
        }
      }
      let persistentIds = new Set;
      for (const { id, tagName } of newIdElements) {
        if (persistentIds.has(id)) {
          duplicateIds.add(id);
        } else if (oldIdTagNameMap.get(id) === tagName) {
          persistentIds.add(id);
        }
      }
      for (const id of duplicateIds) {
        persistentIds.delete(id);
      }
      return persistentIds;
    }
    return createMorphContext2;
  }();
  const { normalizeElement, normalizeParent } = function() {
    const generatedByIdiomorph = new WeakSet;
    function normalizeElement2(content) {
      if (content instanceof Document) {
        return content.documentElement;
      } else {
        return content;
      }
    }
    function normalizeParent2(newContent) {
      if (newContent == null) {
        return document.createElement("div");
      } else if (typeof newContent === "string") {
        return normalizeParent2(parseContent(newContent));
      } else if (generatedByIdiomorph.has(newContent)) {
        return newContent;
      } else if (newContent instanceof Node) {
        if (newContent.parentNode) {
          return new SlicedParentNode(newContent);
        } else {
          const dummyParent = document.createElement("div");
          dummyParent.append(newContent);
          return dummyParent;
        }
      } else {
        const dummyParent = document.createElement("div");
        for (const elt of [...newContent]) {
          dummyParent.append(elt);
        }
        return dummyParent;
      }
    }

    class SlicedParentNode {
      constructor(node) {
        this.originalNode = node;
        this.realParentNode = node.parentNode;
        this.previousSibling = node.previousSibling;
        this.nextSibling = node.nextSibling;
      }
      get childNodes() {
        const nodes = [];
        let cursor = this.previousSibling ? this.previousSibling.nextSibling : this.realParentNode.firstChild;
        while (cursor && cursor != this.nextSibling) {
          nodes.push(cursor);
          cursor = cursor.nextSibling;
        }
        return nodes;
      }
      querySelectorAll(selector) {
        return this.childNodes.reduce((results, node) => {
          if (node instanceof Element) {
            if (node.matches(selector))
              results.push(node);
            const nodeList = node.querySelectorAll(selector);
            for (let i = 0;i < nodeList.length; i++) {
              results.push(nodeList[i]);
            }
          }
          return results;
        }, []);
      }
      insertBefore(node, referenceNode) {
        return this.realParentNode.insertBefore(node, referenceNode);
      }
      moveBefore(node, referenceNode) {
        return this.realParentNode.moveBefore(node, referenceNode);
      }
      get __idiomorphRoot() {
        return this.originalNode;
      }
    }
    function parseContent(newContent) {
      let parser = new DOMParser;
      let contentWithSvgsRemoved = newContent.replace(/<svg(\s[^>]*>|>)([\s\S]*?)<\/svg>/gim, "");
      if (contentWithSvgsRemoved.match(/<\/html>/) || contentWithSvgsRemoved.match(/<\/head>/) || contentWithSvgsRemoved.match(/<\/body>/)) {
        let content = parser.parseFromString(newContent, "text/html");
        if (contentWithSvgsRemoved.match(/<\/html>/)) {
          generatedByIdiomorph.add(content);
          return content;
        } else {
          let htmlElement = content.firstChild;
          if (htmlElement) {
            generatedByIdiomorph.add(htmlElement);
          }
          return htmlElement;
        }
      } else {
        let responseDoc = parser.parseFromString("<body><template>" + newContent + "</template></body>", "text/html");
        let content = responseDoc.body.querySelector("template").content;
        generatedByIdiomorph.add(content);
        return content;
      }
    }
    return { normalizeElement: normalizeElement2, normalizeParent: normalizeParent2 };
  }();
  return {
    morph,
    defaults
  };
}();
function morphElements(currentElement, newElement, { callbacks, ...options } = {}) {
  Idiomorph.morph(currentElement, newElement, {
    ...options,
    callbacks: new DefaultIdiomorphCallbacks(callbacks)
  });
}
function morphChildren(currentElement, newElement, options = {}) {
  morphElements(currentElement, newElement.childNodes, {
    ...options,
    morphStyle: "innerHTML"
  });
}
function shouldRefreshFrameWithMorphing(currentFrame, newFrame) {
  return currentFrame instanceof FrameElement && currentFrame.shouldReloadWithMorph && (!newFrame || areFramesCompatibleForRefreshing(currentFrame, newFrame)) && !currentFrame.closest("[data-turbo-permanent]");
}
function areFramesCompatibleForRefreshing(currentFrame, newFrame) {
  return newFrame instanceof Element && newFrame.nodeName === "TURBO-FRAME" && currentFrame.id === newFrame.id && (!newFrame.getAttribute("src") || urlsAreEqual(currentFrame.src, newFrame.getAttribute("src")));
}
function closestFrameReloadableWithMorphing(node) {
  return node.parentElement.closest("turbo-frame[src][refresh=morph]");
}

class DefaultIdiomorphCallbacks {
  #beforeNodeMorphed;
  constructor({ beforeNodeMorphed } = {}) {
    this.#beforeNodeMorphed = beforeNodeMorphed || (() => true);
  }
  beforeNodeAdded = (node) => {
    return !(node.id && node.hasAttribute("data-turbo-permanent") && document.getElementById(node.id));
  };
  beforeNodeMorphed = (currentElement, newElement) => {
    if (currentElement instanceof Element) {
      if (!currentElement.hasAttribute("data-turbo-permanent") && this.#beforeNodeMorphed(currentElement, newElement)) {
        const event = dispatch("turbo:before-morph-element", {
          cancelable: true,
          target: currentElement,
          detail: { currentElement, newElement }
        });
        return !event.defaultPrevented;
      } else {
        return false;
      }
    }
  };
  beforeAttributeUpdated = (attributeName, target, mutationType) => {
    const event = dispatch("turbo:before-morph-attribute", {
      cancelable: true,
      target,
      detail: { attributeName, mutationType }
    });
    return !event.defaultPrevented;
  };
  beforeNodeRemoved = (node) => {
    return this.beforeNodeMorphed(node);
  };
  afterNodeMorphed = (currentElement, newElement) => {
    if (currentElement instanceof Element) {
      dispatch("turbo:morph-element", {
        target: currentElement,
        detail: { currentElement, newElement }
      });
    }
  };
}

class MorphingFrameRenderer extends FrameRenderer {
  static renderElement(currentElement, newElement) {
    dispatch("turbo:before-frame-morph", {
      target: currentElement,
      detail: { currentElement, newElement }
    });
    morphChildren(currentElement, newElement, {
      callbacks: {
        beforeNodeMorphed: (node, newNode) => {
          if (shouldRefreshFrameWithMorphing(node, newNode) && closestFrameReloadableWithMorphing(node) === currentElement) {
            node.reload();
            return false;
          }
          return true;
        }
      }
    });
  }
  async preservingPermanentElements(callback) {
    return await callback();
  }
}

class ProgressBar {
  static animationDuration = 300;
  static get defaultCSS() {
    return unindent`
      .turbo-progress-bar {
        position: fixed;
        display: block;
        top: 0;
        left: 0;
        height: 3px;
        background: #0076ff;
        z-index: 2147483647;
        transition:
          width ${ProgressBar.animationDuration}ms ease-out,
          opacity ${ProgressBar.animationDuration / 2}ms ${ProgressBar.animationDuration / 2}ms ease-in;
        transform: translate3d(0, 0, 0);
      }
    `;
  }
  hiding = false;
  value = 0;
  visible = false;
  constructor() {
    this.stylesheetElement = this.createStylesheetElement();
    this.progressElement = this.createProgressElement();
    this.installStylesheetElement();
    this.setValue(0);
  }
  show() {
    if (!this.visible) {
      this.visible = true;
      this.installProgressElement();
      this.startTrickling();
    }
  }
  hide() {
    if (this.visible && !this.hiding) {
      this.hiding = true;
      this.fadeProgressElement(() => {
        this.uninstallProgressElement();
        this.stopTrickling();
        this.visible = false;
        this.hiding = false;
      });
    }
  }
  setValue(value) {
    this.value = value;
    this.refresh();
  }
  installStylesheetElement() {
    document.head.insertBefore(this.stylesheetElement, document.head.firstChild);
  }
  installProgressElement() {
    this.progressElement.style.width = "0";
    this.progressElement.style.opacity = "1";
    document.documentElement.insertBefore(this.progressElement, document.body);
    this.refresh();
  }
  fadeProgressElement(callback) {
    this.progressElement.style.opacity = "0";
    setTimeout(callback, ProgressBar.animationDuration * 1.5);
  }
  uninstallProgressElement() {
    if (this.progressElement.parentNode) {
      document.documentElement.removeChild(this.progressElement);
    }
  }
  startTrickling() {
    if (!this.trickleInterval) {
      this.trickleInterval = window.setInterval(this.trickle, ProgressBar.animationDuration);
    }
  }
  stopTrickling() {
    window.clearInterval(this.trickleInterval);
    delete this.trickleInterval;
  }
  trickle = () => {
    this.setValue(this.value + Math.random() / 100);
  };
  refresh() {
    requestAnimationFrame(() => {
      this.progressElement.style.width = `${10 + this.value * 90}%`;
    });
  }
  createStylesheetElement() {
    const element = document.createElement("style");
    element.type = "text/css";
    element.textContent = ProgressBar.defaultCSS;
    const cspNonce = getCspNonce();
    if (cspNonce) {
      element.nonce = cspNonce;
    }
    return element;
  }
  createProgressElement() {
    const element = document.createElement("div");
    element.className = "turbo-progress-bar";
    return element;
  }
}

class HeadSnapshot extends Snapshot {
  detailsByOuterHTML = this.children.filter((element) => !elementIsNoscript(element)).map((element) => elementWithoutNonce(element)).reduce((result, element) => {
    const { outerHTML } = element;
    const details = outerHTML in result ? result[outerHTML] : {
      type: elementType(element),
      tracked: elementIsTracked(element),
      elements: []
    };
    return {
      ...result,
      [outerHTML]: {
        ...details,
        elements: [...details.elements, element]
      }
    };
  }, {});
  get trackedElementSignature() {
    return Object.keys(this.detailsByOuterHTML).filter((outerHTML) => this.detailsByOuterHTML[outerHTML].tracked).join("");
  }
  getScriptElementsNotInSnapshot(snapshot) {
    return this.getElementsMatchingTypeNotInSnapshot("script", snapshot);
  }
  getStylesheetElementsNotInSnapshot(snapshot) {
    return this.getElementsMatchingTypeNotInSnapshot("stylesheet", snapshot);
  }
  getElementsMatchingTypeNotInSnapshot(matchedType, snapshot) {
    return Object.keys(this.detailsByOuterHTML).filter((outerHTML) => !(outerHTML in snapshot.detailsByOuterHTML)).map((outerHTML) => this.detailsByOuterHTML[outerHTML]).filter(({ type }) => type == matchedType).map(({ elements: [element] }) => element);
  }
  get provisionalElements() {
    return Object.keys(this.detailsByOuterHTML).reduce((result, outerHTML) => {
      const { type, tracked, elements } = this.detailsByOuterHTML[outerHTML];
      if (type == null && !tracked) {
        return [...result, ...elements];
      } else if (elements.length > 1) {
        return [...result, ...elements.slice(1)];
      } else {
        return result;
      }
    }, []);
  }
  getMetaValue(name) {
    const element = this.findMetaElementByName(name);
    return element ? element.getAttribute("content") : null;
  }
  findMetaElementByName(name) {
    return Object.keys(this.detailsByOuterHTML).reduce((result, outerHTML) => {
      const {
        elements: [element]
      } = this.detailsByOuterHTML[outerHTML];
      return elementIsMetaElementWithName(element, name) ? element : result;
    }, undefined | undefined);
  }
}
function elementType(element) {
  if (elementIsScript(element)) {
    return "script";
  } else if (elementIsStylesheet(element)) {
    return "stylesheet";
  }
}
function elementIsTracked(element) {
  return element.getAttribute("data-turbo-track") == "reload";
}
function elementIsScript(element) {
  const tagName = element.localName;
  return tagName == "script";
}
function elementIsNoscript(element) {
  const tagName = element.localName;
  return tagName == "noscript";
}
function elementIsStylesheet(element) {
  const tagName = element.localName;
  return tagName == "style" || tagName == "link" && element.getAttribute("rel") == "stylesheet";
}
function elementIsMetaElementWithName(element, name) {
  const tagName = element.localName;
  return tagName == "meta" && element.getAttribute("name") == name;
}
function elementWithoutNonce(element) {
  if (element.hasAttribute("nonce")) {
    element.setAttribute("nonce", "");
  }
  return element;
}

class PageSnapshot extends Snapshot {
  static fromHTMLString(html = "") {
    return this.fromDocument(parseHTMLDocument(html));
  }
  static fromElement(element) {
    return this.fromDocument(element.ownerDocument);
  }
  static fromDocument({ documentElement, body, head }) {
    return new this(documentElement, body, new HeadSnapshot(head));
  }
  constructor(documentElement, body, headSnapshot) {
    super(body);
    this.documentElement = documentElement;
    this.headSnapshot = headSnapshot;
  }
  clone() {
    const clonedElement = this.element.cloneNode(true);
    const selectElements = this.element.querySelectorAll("select");
    const clonedSelectElements = clonedElement.querySelectorAll("select");
    for (const [index, source] of selectElements.entries()) {
      const clone = clonedSelectElements[index];
      for (const option of clone.selectedOptions)
        option.selected = false;
      for (const option of source.selectedOptions)
        clone.options[option.index].selected = true;
    }
    for (const clonedPasswordInput of clonedElement.querySelectorAll('input[type="password"]')) {
      clonedPasswordInput.value = "";
    }
    for (const clonedNoscriptElement of clonedElement.querySelectorAll("noscript")) {
      clonedNoscriptElement.remove();
    }
    return new PageSnapshot(this.documentElement, clonedElement, this.headSnapshot);
  }
  get lang() {
    return this.documentElement.getAttribute("lang");
  }
  get dir() {
    return this.documentElement.getAttribute("dir");
  }
  get headElement() {
    return this.headSnapshot.element;
  }
  get rootLocation() {
    const root = this.getSetting("root") ?? "/";
    return expandURL(root);
  }
  get cacheControlValue() {
    return this.getSetting("cache-control");
  }
  get isPreviewable() {
    return this.cacheControlValue != "no-preview";
  }
  get isCacheable() {
    return this.cacheControlValue != "no-cache";
  }
  get isVisitable() {
    return this.getSetting("visit-control") != "reload";
  }
  get prefersViewTransitions() {
    const viewTransitionEnabled = this.getSetting("view-transition") === "true" || this.headSnapshot.getMetaValue("view-transition") === "same-origin";
    return viewTransitionEnabled && !window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }
  get refreshMethod() {
    return this.getSetting("refresh-method");
  }
  get refreshScroll() {
    return this.getSetting("refresh-scroll");
  }
  getSetting(name) {
    return this.headSnapshot.getMetaValue(`turbo-${name}`);
  }
}

class ViewTransitioner {
  #viewTransitionStarted = false;
  #lastOperation = Promise.resolve();
  renderChange(useViewTransition, render) {
    if (useViewTransition && this.viewTransitionsAvailable && !this.#viewTransitionStarted) {
      this.#viewTransitionStarted = true;
      this.#lastOperation = this.#lastOperation.then(async () => {
        await document.startViewTransition(render).finished;
      });
    } else {
      this.#lastOperation = this.#lastOperation.then(render);
    }
    return this.#lastOperation;
  }
  get viewTransitionsAvailable() {
    return document.startViewTransition;
  }
}
var defaultOptions = {
  action: "advance",
  historyChanged: false,
  visitCachedSnapshot: () => {
  },
  willRender: true,
  updateHistory: true,
  shouldCacheSnapshot: true,
  acceptsStreamResponse: false,
  refresh: {}
};
var TimingMetric = {
  visitStart: "visitStart",
  requestStart: "requestStart",
  requestEnd: "requestEnd",
  visitEnd: "visitEnd"
};
var VisitState = {
  initialized: "initialized",
  started: "started",
  canceled: "canceled",
  failed: "failed",
  completed: "completed"
};
var SystemStatusCode = {
  networkFailure: 0,
  timeoutFailure: -1,
  contentTypeMismatch: -2
};
var Direction = {
  advance: "forward",
  restore: "back",
  replace: "none"
};

class Visit {
  identifier = uuid();
  timingMetrics = {};
  followedRedirect = false;
  historyChanged = false;
  scrolled = false;
  shouldCacheSnapshot = true;
  acceptsStreamResponse = false;
  snapshotCached = false;
  state = VisitState.initialized;
  viewTransitioner = new ViewTransitioner;
  constructor(delegate, location2, restorationIdentifier, options = {}) {
    this.delegate = delegate;
    this.location = location2;
    this.restorationIdentifier = restorationIdentifier || uuid();
    const {
      action,
      historyChanged,
      referrer,
      snapshot,
      snapshotHTML,
      response,
      visitCachedSnapshot,
      willRender,
      updateHistory,
      shouldCacheSnapshot,
      acceptsStreamResponse,
      direction,
      refresh
    } = {
      ...defaultOptions,
      ...options
    };
    this.action = action;
    this.historyChanged = historyChanged;
    this.referrer = referrer;
    this.snapshot = snapshot;
    this.snapshotHTML = snapshotHTML;
    this.response = response;
    this.isPageRefresh = this.view.isPageRefresh(this);
    this.visitCachedSnapshot = visitCachedSnapshot;
    this.willRender = willRender;
    this.updateHistory = updateHistory;
    this.scrolled = !willRender;
    this.shouldCacheSnapshot = shouldCacheSnapshot;
    this.acceptsStreamResponse = acceptsStreamResponse;
    this.direction = direction || Direction[action];
    this.refresh = refresh;
  }
  get adapter() {
    return this.delegate.adapter;
  }
  get view() {
    return this.delegate.view;
  }
  get history() {
    return this.delegate.history;
  }
  get restorationData() {
    return this.history.getRestorationDataForIdentifier(this.restorationIdentifier);
  }
  start() {
    if (this.state == VisitState.initialized) {
      this.recordTimingMetric(TimingMetric.visitStart);
      this.state = VisitState.started;
      this.adapter.visitStarted(this);
      this.delegate.visitStarted(this);
    }
  }
  cancel() {
    if (this.state == VisitState.started) {
      if (this.request) {
        this.request.cancel();
      }
      this.cancelRender();
      this.state = VisitState.canceled;
    }
  }
  complete() {
    if (this.state == VisitState.started) {
      this.recordTimingMetric(TimingMetric.visitEnd);
      this.adapter.visitCompleted(this);
      this.state = VisitState.completed;
      this.followRedirect();
      if (!this.followedRedirect) {
        this.delegate.visitCompleted(this);
      }
    }
  }
  fail() {
    if (this.state == VisitState.started) {
      this.state = VisitState.failed;
      this.adapter.visitFailed(this);
      this.delegate.visitCompleted(this);
    }
  }
  changeHistory() {
    if (!this.historyChanged && this.updateHistory) {
      const actionForHistory = this.location.href === this.referrer?.href ? "replace" : this.action;
      const method = getHistoryMethodForAction(actionForHistory);
      this.history.update(method, this.location, this.restorationIdentifier);
      this.historyChanged = true;
    }
  }
  issueRequest() {
    if (this.hasPreloadedResponse()) {
      this.simulateRequest();
    } else if (this.shouldIssueRequest() && !this.request) {
      this.request = new FetchRequest(this, FetchMethod.get, this.location);
      this.request.perform();
    }
  }
  simulateRequest() {
    if (this.response) {
      this.startRequest();
      this.recordResponse();
      this.finishRequest();
    }
  }
  startRequest() {
    this.recordTimingMetric(TimingMetric.requestStart);
    this.adapter.visitRequestStarted(this);
  }
  recordResponse(response = this.response) {
    this.response = response;
    if (response) {
      const { statusCode } = response;
      if (isSuccessful(statusCode)) {
        this.adapter.visitRequestCompleted(this);
      } else {
        this.adapter.visitRequestFailedWithStatusCode(this, statusCode);
      }
    }
  }
  finishRequest() {
    this.recordTimingMetric(TimingMetric.requestEnd);
    this.adapter.visitRequestFinished(this);
  }
  loadResponse() {
    if (this.response) {
      const { statusCode, responseHTML } = this.response;
      this.render(async () => {
        if (this.shouldCacheSnapshot)
          this.cacheSnapshot();
        if (this.view.renderPromise)
          await this.view.renderPromise;
        if (isSuccessful(statusCode) && responseHTML != null) {
          const snapshot = PageSnapshot.fromHTMLString(responseHTML);
          await this.renderPageSnapshot(snapshot, false);
          this.adapter.visitRendered(this);
          this.complete();
        } else {
          await this.view.renderError(PageSnapshot.fromHTMLString(responseHTML), this);
          this.adapter.visitRendered(this);
          this.fail();
        }
      });
    }
  }
  getCachedSnapshot() {
    const snapshot = this.view.getCachedSnapshotForLocation(this.location) || this.getPreloadedSnapshot();
    if (snapshot && (!getAnchor(this.location) || snapshot.hasAnchor(getAnchor(this.location)))) {
      if (this.action == "restore" || snapshot.isPreviewable) {
        return snapshot;
      }
    }
  }
  getPreloadedSnapshot() {
    if (this.snapshotHTML) {
      return PageSnapshot.fromHTMLString(this.snapshotHTML);
    }
  }
  hasCachedSnapshot() {
    return this.getCachedSnapshot() != null;
  }
  loadCachedSnapshot() {
    const snapshot = this.getCachedSnapshot();
    if (snapshot) {
      const isPreview = this.shouldIssueRequest();
      this.render(async () => {
        this.cacheSnapshot();
        if (this.isPageRefresh) {
          this.adapter.visitRendered(this);
        } else {
          if (this.view.renderPromise)
            await this.view.renderPromise;
          await this.renderPageSnapshot(snapshot, isPreview);
          this.adapter.visitRendered(this);
          if (!isPreview) {
            this.complete();
          }
        }
      });
    }
  }
  followRedirect() {
    if (this.redirectedToLocation && !this.followedRedirect && this.response?.redirected) {
      this.adapter.visitProposedToLocation(this.redirectedToLocation, {
        action: "replace",
        response: this.response,
        shouldCacheSnapshot: false,
        willRender: false
      });
      this.followedRedirect = true;
    }
  }
  prepareRequest(request) {
    if (this.acceptsStreamResponse) {
      request.acceptResponseType(StreamMessage.contentType);
    }
  }
  requestStarted() {
    this.startRequest();
  }
  requestPreventedHandlingResponse(_request, _response) {
  }
  async requestSucceededWithResponse(request, response) {
    const responseHTML = await response.responseHTML;
    const { redirected, statusCode } = response;
    if (responseHTML == undefined) {
      this.recordResponse({
        statusCode: SystemStatusCode.contentTypeMismatch,
        redirected
      });
    } else {
      this.redirectedToLocation = response.redirected ? response.location : undefined;
      this.recordResponse({ statusCode, responseHTML, redirected });
    }
  }
  async requestFailedWithResponse(request, response) {
    const responseHTML = await response.responseHTML;
    const { redirected, statusCode } = response;
    if (responseHTML == undefined) {
      this.recordResponse({
        statusCode: SystemStatusCode.contentTypeMismatch,
        redirected
      });
    } else {
      this.recordResponse({ statusCode, responseHTML, redirected });
    }
  }
  requestErrored(_request, _error) {
    this.recordResponse({
      statusCode: SystemStatusCode.networkFailure,
      redirected: false
    });
  }
  requestFinished() {
    this.finishRequest();
  }
  performScroll() {
    if (!this.scrolled && !this.view.forceReloaded && !this.view.shouldPreserveScrollPosition(this)) {
      if (this.action == "restore") {
        this.scrollToRestoredPosition() || this.scrollToAnchor() || this.view.scrollToTop();
      } else {
        this.scrollToAnchor() || this.view.scrollToTop();
      }
      this.scrolled = true;
    }
  }
  scrollToRestoredPosition() {
    const { scrollPosition } = this.restorationData;
    if (scrollPosition) {
      this.view.scrollToPosition(scrollPosition);
      return true;
    }
  }
  scrollToAnchor() {
    const anchor = getAnchor(this.location);
    if (anchor != null) {
      this.view.scrollToAnchor(anchor);
      return true;
    }
  }
  recordTimingMetric(metric) {
    this.timingMetrics[metric] = new Date().getTime();
  }
  getTimingMetrics() {
    return { ...this.timingMetrics };
  }
  hasPreloadedResponse() {
    return typeof this.response == "object";
  }
  shouldIssueRequest() {
    if (this.action == "restore") {
      return !this.hasCachedSnapshot();
    } else {
      return this.willRender;
    }
  }
  cacheSnapshot() {
    if (!this.snapshotCached) {
      this.view.cacheSnapshot(this.snapshot).then((snapshot) => snapshot && this.visitCachedSnapshot(snapshot));
      this.snapshotCached = true;
    }
  }
  async render(callback) {
    this.cancelRender();
    await new Promise((resolve) => {
      this.frame = document.visibilityState === "hidden" ? setTimeout(() => resolve(), 0) : requestAnimationFrame(() => resolve());
    });
    await callback();
    delete this.frame;
  }
  async renderPageSnapshot(snapshot, isPreview) {
    await this.viewTransitioner.renderChange(this.view.shouldTransitionTo(snapshot), async () => {
      await this.view.renderPage(snapshot, isPreview, this.willRender, this);
      this.performScroll();
    });
  }
  cancelRender() {
    if (this.frame) {
      cancelAnimationFrame(this.frame);
      delete this.frame;
    }
  }
}
function isSuccessful(statusCode) {
  return statusCode >= 200 && statusCode < 300;
}

class BrowserAdapter {
  progressBar = new ProgressBar;
  constructor(session) {
    this.session = session;
  }
  visitProposedToLocation(location2, options) {
    if (locationIsVisitable(location2, this.navigator.rootLocation)) {
      this.navigator.startVisit(location2, options?.restorationIdentifier || uuid(), options);
    } else {
      window.location.href = location2.toString();
    }
  }
  visitStarted(visit) {
    this.location = visit.location;
    this.redirectedToLocation = null;
    visit.loadCachedSnapshot();
    visit.issueRequest();
  }
  visitRequestStarted(visit) {
    this.progressBar.setValue(0);
    if (visit.hasCachedSnapshot() || visit.action != "restore") {
      this.showVisitProgressBarAfterDelay();
    } else {
      this.showProgressBar();
    }
  }
  visitRequestCompleted(visit) {
    visit.loadResponse();
    if (visit.response.redirected) {
      this.redirectedToLocation = visit.redirectedToLocation;
    }
  }
  visitRequestFailedWithStatusCode(visit, statusCode) {
    switch (statusCode) {
      case SystemStatusCode.networkFailure:
      case SystemStatusCode.timeoutFailure:
      case SystemStatusCode.contentTypeMismatch:
        return this.reload({
          reason: "request_failed",
          context: {
            statusCode
          }
        });
      default:
        return visit.loadResponse();
    }
  }
  visitRequestFinished(_visit) {
  }
  visitCompleted(_visit) {
    this.progressBar.setValue(1);
    this.hideVisitProgressBar();
  }
  pageInvalidated(reason) {
    this.reload(reason);
  }
  visitFailed(_visit) {
    this.progressBar.setValue(1);
    this.hideVisitProgressBar();
  }
  visitRendered(_visit) {
  }
  linkPrefetchingIsEnabledForLocation(location2) {
    return true;
  }
  formSubmissionStarted(_formSubmission) {
    this.progressBar.setValue(0);
    this.showFormProgressBarAfterDelay();
  }
  formSubmissionFinished(_formSubmission) {
    this.progressBar.setValue(1);
    this.hideFormProgressBar();
  }
  showVisitProgressBarAfterDelay() {
    this.visitProgressBarTimeout = window.setTimeout(this.showProgressBar, this.session.progressBarDelay);
  }
  hideVisitProgressBar() {
    this.progressBar.hide();
    if (this.visitProgressBarTimeout != null) {
      window.clearTimeout(this.visitProgressBarTimeout);
      delete this.visitProgressBarTimeout;
    }
  }
  showFormProgressBarAfterDelay() {
    if (this.formProgressBarTimeout == null) {
      this.formProgressBarTimeout = window.setTimeout(this.showProgressBar, this.session.progressBarDelay);
    }
  }
  hideFormProgressBar() {
    this.progressBar.hide();
    if (this.formProgressBarTimeout != null) {
      window.clearTimeout(this.formProgressBarTimeout);
      delete this.formProgressBarTimeout;
    }
  }
  showProgressBar = () => {
    this.progressBar.show();
  };
  reload(reason) {
    dispatch("turbo:reload", { detail: reason });
    window.location.href = (this.redirectedToLocation || this.location)?.toString() || window.location.href;
  }
  get navigator() {
    return this.session.navigator;
  }
}

class CacheObserver {
  selector = "[data-turbo-temporary]";
  started = false;
  start() {
    if (!this.started) {
      this.started = true;
      addEventListener("turbo:before-cache", this.removeTemporaryElements, false);
    }
  }
  stop() {
    if (this.started) {
      this.started = false;
      removeEventListener("turbo:before-cache", this.removeTemporaryElements, false);
    }
  }
  removeTemporaryElements = (_event) => {
    for (const element of this.temporaryElements) {
      element.remove();
    }
  };
  get temporaryElements() {
    return [...document.querySelectorAll(this.selector)];
  }
}

class FrameRedirector {
  constructor(session, element) {
    this.session = session;
    this.element = element;
    this.linkInterceptor = new LinkInterceptor(this, element);
    this.formSubmitObserver = new FormSubmitObserver(this, element);
  }
  start() {
    this.linkInterceptor.start();
    this.formSubmitObserver.start();
  }
  stop() {
    this.linkInterceptor.stop();
    this.formSubmitObserver.stop();
  }
  shouldInterceptLinkClick(element, _location, _event) {
    return this.#shouldRedirect(element);
  }
  linkClickIntercepted(element, url, event) {
    const frame = this.#findFrameElement(element);
    if (frame) {
      frame.delegate.linkClickIntercepted(element, url, event);
    }
  }
  willSubmitForm(element, submitter2) {
    return element.closest("turbo-frame") == null && this.#shouldSubmit(element, submitter2) && this.#shouldRedirect(element, submitter2);
  }
  formSubmitted(element, submitter2) {
    const frame = this.#findFrameElement(element, submitter2);
    if (frame) {
      frame.delegate.formSubmitted(element, submitter2);
    }
  }
  #shouldSubmit(form, submitter2) {
    const action = getAction$1(form, submitter2);
    const meta = this.element.ownerDocument.querySelector(`meta[name="turbo-root"]`);
    const rootLocation = expandURL(meta?.content ?? "/");
    return this.#shouldRedirect(form, submitter2) && locationIsVisitable(action, rootLocation);
  }
  #shouldRedirect(element, submitter2) {
    const isNavigatable = element instanceof HTMLFormElement ? this.session.submissionIsNavigatable(element, submitter2) : this.session.elementIsNavigatable(element);
    if (isNavigatable) {
      const frame = this.#findFrameElement(element, submitter2);
      return frame ? frame != element.closest("turbo-frame") : false;
    } else {
      return false;
    }
  }
  #findFrameElement(element, submitter2) {
    const id = submitter2?.getAttribute("data-turbo-frame") || element.getAttribute("data-turbo-frame");
    if (id && id != "_top") {
      const frame = this.element.querySelector(`#${id}:not([disabled])`);
      if (frame instanceof FrameElement) {
        return frame;
      }
    }
  }
}

class History {
  location;
  restorationIdentifier = uuid();
  restorationData = {};
  started = false;
  currentIndex = 0;
  constructor(delegate) {
    this.delegate = delegate;
  }
  start() {
    if (!this.started) {
      addEventListener("popstate", this.onPopState, false);
      this.currentIndex = history.state?.turbo?.restorationIndex || 0;
      this.started = true;
      this.replace(new URL(window.location.href));
    }
  }
  stop() {
    if (this.started) {
      removeEventListener("popstate", this.onPopState, false);
      this.started = false;
    }
  }
  push(location2, restorationIdentifier) {
    this.update(history.pushState, location2, restorationIdentifier);
  }
  replace(location2, restorationIdentifier) {
    this.update(history.replaceState, location2, restorationIdentifier);
  }
  update(method, location2, restorationIdentifier = uuid()) {
    if (method === history.pushState)
      ++this.currentIndex;
    const state = { turbo: { restorationIdentifier, restorationIndex: this.currentIndex } };
    method.call(history, state, "", location2.href);
    this.location = location2;
    this.restorationIdentifier = restorationIdentifier;
  }
  getRestorationDataForIdentifier(restorationIdentifier) {
    return this.restorationData[restorationIdentifier] || {};
  }
  updateRestorationData(additionalData) {
    const { restorationIdentifier } = this;
    const restorationData = this.restorationData[restorationIdentifier];
    this.restorationData[restorationIdentifier] = {
      ...restorationData,
      ...additionalData
    };
  }
  assumeControlOfScrollRestoration() {
    if (!this.previousScrollRestoration) {
      this.previousScrollRestoration = history.scrollRestoration ?? "auto";
      history.scrollRestoration = "manual";
    }
  }
  relinquishControlOfScrollRestoration() {
    if (this.previousScrollRestoration) {
      history.scrollRestoration = this.previousScrollRestoration;
      delete this.previousScrollRestoration;
    }
  }
  onPopState = (event) => {
    const { turbo } = event.state || {};
    this.location = new URL(window.location.href);
    if (turbo) {
      const { restorationIdentifier, restorationIndex } = turbo;
      this.restorationIdentifier = restorationIdentifier;
      const direction = restorationIndex > this.currentIndex ? "forward" : "back";
      this.delegate.historyPoppedToLocationWithRestorationIdentifierAndDirection(this.location, restorationIdentifier, direction);
      this.currentIndex = restorationIndex;
    } else {
      this.currentIndex++;
      this.delegate.historyPoppedWithEmptyState(this.location);
    }
  };
}

class LinkPrefetchObserver {
  started = false;
  #prefetchedLink = null;
  constructor(delegate, eventTarget) {
    this.delegate = delegate;
    this.eventTarget = eventTarget;
  }
  start() {
    if (this.started)
      return;
    if (this.eventTarget.readyState === "loading") {
      this.eventTarget.addEventListener("DOMContentLoaded", this.#enable, { once: true });
    } else {
      this.#enable();
    }
  }
  stop() {
    if (!this.started)
      return;
    this.eventTarget.removeEventListener("mouseenter", this.#tryToPrefetchRequest, {
      capture: true,
      passive: true
    });
    this.eventTarget.removeEventListener("mouseleave", this.#cancelRequestIfObsolete, {
      capture: true,
      passive: true
    });
    this.eventTarget.removeEventListener("turbo:before-fetch-request", this.#tryToUsePrefetchedRequest, true);
    this.started = false;
  }
  #enable = () => {
    this.eventTarget.addEventListener("mouseenter", this.#tryToPrefetchRequest, {
      capture: true,
      passive: true
    });
    this.eventTarget.addEventListener("mouseleave", this.#cancelRequestIfObsolete, {
      capture: true,
      passive: true
    });
    this.eventTarget.addEventListener("turbo:before-fetch-request", this.#tryToUsePrefetchedRequest, true);
    this.started = true;
  };
  #tryToPrefetchRequest = (event) => {
    if (getMetaContent("turbo-prefetch") === "false")
      return;
    const target = event.target;
    const isLink = target.matches && target.matches("a[href]:not([target^=_]):not([download])");
    if (isLink && this.#isPrefetchable(target)) {
      const link = target;
      const location2 = getLocationForLink(link);
      if (this.delegate.canPrefetchRequestToLocation(link, location2)) {
        this.#prefetchedLink = link;
        const fetchRequest = new FetchRequest(this, FetchMethod.get, location2, new URLSearchParams, target);
        fetchRequest.fetchOptions.priority = "low";
        prefetchCache.putLater(location2, fetchRequest, this.#cacheTtl);
      }
    }
  };
  #cancelRequestIfObsolete = (event) => {
    if (event.target === this.#prefetchedLink)
      this.#cancelPrefetchRequest();
  };
  #cancelPrefetchRequest = () => {
    prefetchCache.clear();
    this.#prefetchedLink = null;
  };
  #tryToUsePrefetchedRequest = (event) => {
    if (event.target.tagName !== "FORM" && event.detail.fetchOptions.method === "GET") {
      const cached = prefetchCache.get(event.detail.url);
      if (cached) {
        event.detail.fetchRequest = cached;
      }
      prefetchCache.clear();
    }
  };
  prepareRequest(request) {
    const link = request.target;
    request.headers["X-Sec-Purpose"] = "prefetch";
    const turboFrame = link.closest("turbo-frame");
    const turboFrameTarget = link.getAttribute("data-turbo-frame") || turboFrame?.getAttribute("target") || turboFrame?.id;
    if (turboFrameTarget && turboFrameTarget !== "_top") {
      request.headers["Turbo-Frame"] = turboFrameTarget;
    }
  }
  requestSucceededWithResponse() {
  }
  requestStarted(fetchRequest) {
  }
  requestErrored(fetchRequest) {
  }
  requestFinished(fetchRequest) {
  }
  requestPreventedHandlingResponse(fetchRequest, fetchResponse) {
  }
  requestFailedWithResponse(fetchRequest, fetchResponse) {
  }
  get #cacheTtl() {
    return Number(getMetaContent("turbo-prefetch-cache-time")) || cacheTtl;
  }
  #isPrefetchable(link) {
    const href = link.getAttribute("href");
    if (!href)
      return false;
    if (unfetchableLink(link))
      return false;
    if (linkToTheSamePage(link))
      return false;
    if (linkOptsOut(link))
      return false;
    if (nonSafeLink(link))
      return false;
    if (eventPrevented(link))
      return false;
    return true;
  }
}
var unfetchableLink = (link) => {
  return link.origin !== document.location.origin || !["http:", "https:"].includes(link.protocol) || link.hasAttribute("target");
};
var linkToTheSamePage = (link) => {
  return link.pathname + link.search === document.location.pathname + document.location.search || link.href.startsWith("#");
};
var linkOptsOut = (link) => {
  if (link.getAttribute("data-turbo-prefetch") === "false")
    return true;
  if (link.getAttribute("data-turbo") === "false")
    return true;
  const turboPrefetchParent = findClosestRecursively(link, "[data-turbo-prefetch]");
  if (turboPrefetchParent && turboPrefetchParent.getAttribute("data-turbo-prefetch") === "false")
    return true;
  return false;
};
var nonSafeLink = (link) => {
  const turboMethod = link.getAttribute("data-turbo-method");
  if (turboMethod && turboMethod.toLowerCase() !== "get")
    return true;
  if (isUJS(link))
    return true;
  if (link.hasAttribute("data-turbo-confirm"))
    return true;
  if (link.hasAttribute("data-turbo-stream"))
    return true;
  return false;
};
var isUJS = (link) => {
  return link.hasAttribute("data-remote") || link.hasAttribute("data-behavior") || link.hasAttribute("data-confirm") || link.hasAttribute("data-method");
};
var eventPrevented = (link) => {
  const event = dispatch("turbo:before-prefetch", { target: link, cancelable: true });
  return event.defaultPrevented;
};

class Navigator {
  constructor(delegate) {
    this.delegate = delegate;
  }
  proposeVisit(location2, options = {}) {
    if (this.delegate.allowsVisitingLocationWithAction(location2, options.action)) {
      this.delegate.visitProposedToLocation(location2, options);
    }
  }
  startVisit(locatable, restorationIdentifier, options = {}) {
    this.stop();
    this.currentVisit = new Visit(this, expandURL(locatable), restorationIdentifier, {
      referrer: this.location,
      ...options
    });
    this.currentVisit.start();
  }
  submitForm(form, submitter2) {
    this.stop();
    this.formSubmission = new FormSubmission(this, form, submitter2, true);
    this.formSubmission.start();
  }
  stop() {
    if (this.formSubmission) {
      this.formSubmission.stop();
      delete this.formSubmission;
    }
    if (this.currentVisit) {
      this.currentVisit.cancel();
      delete this.currentVisit;
    }
  }
  get adapter() {
    return this.delegate.adapter;
  }
  get view() {
    return this.delegate.view;
  }
  get rootLocation() {
    return this.view.snapshot.rootLocation;
  }
  get history() {
    return this.delegate.history;
  }
  formSubmissionStarted(formSubmission) {
    if (typeof this.adapter.formSubmissionStarted === "function") {
      this.adapter.formSubmissionStarted(formSubmission);
    }
  }
  async formSubmissionSucceededWithResponse(formSubmission, fetchResponse) {
    if (formSubmission == this.formSubmission) {
      const responseHTML = await fetchResponse.responseHTML;
      if (responseHTML) {
        const shouldCacheSnapshot = formSubmission.isSafe;
        if (!shouldCacheSnapshot) {
          this.view.clearSnapshotCache();
        }
        const { statusCode, redirected } = fetchResponse;
        const action = this.#getActionForFormSubmission(formSubmission, fetchResponse);
        const visitOptions = {
          action,
          shouldCacheSnapshot,
          response: { statusCode, responseHTML, redirected }
        };
        this.proposeVisit(fetchResponse.location, visitOptions);
      }
    }
  }
  async formSubmissionFailedWithResponse(formSubmission, fetchResponse) {
    const responseHTML = await fetchResponse.responseHTML;
    if (responseHTML) {
      const snapshot = PageSnapshot.fromHTMLString(responseHTML);
      if (fetchResponse.serverError) {
        await this.view.renderError(snapshot, this.currentVisit);
      } else {
        await this.view.renderPage(snapshot, false, true, this.currentVisit);
      }
      if (snapshot.refreshScroll !== "preserve") {
        this.view.scrollToTop();
      }
      this.view.clearSnapshotCache();
    }
  }
  formSubmissionErrored(formSubmission, error) {
    console.error(error);
  }
  formSubmissionFinished(formSubmission) {
    if (typeof this.adapter.formSubmissionFinished === "function") {
      this.adapter.formSubmissionFinished(formSubmission);
    }
  }
  linkPrefetchingIsEnabledForLocation(location2) {
    if (typeof this.adapter.linkPrefetchingIsEnabledForLocation === "function") {
      return this.adapter.linkPrefetchingIsEnabledForLocation(location2);
    }
    return true;
  }
  visitStarted(visit) {
    this.delegate.visitStarted(visit);
  }
  visitCompleted(visit) {
    this.delegate.visitCompleted(visit);
    delete this.currentVisit;
  }
  locationWithActionIsSamePage(location2, action) {
    return false;
  }
  get location() {
    return this.history.location;
  }
  get restorationIdentifier() {
    return this.history.restorationIdentifier;
  }
  #getActionForFormSubmission(formSubmission, fetchResponse) {
    const { submitter: submitter2, formElement } = formSubmission;
    return getVisitAction(submitter2, formElement) || this.#getDefaultAction(fetchResponse);
  }
  #getDefaultAction(fetchResponse) {
    const sameLocationRedirect = fetchResponse.redirected && fetchResponse.location.href === this.location?.href;
    return sameLocationRedirect ? "replace" : "advance";
  }
}
var PageStage = {
  initial: 0,
  loading: 1,
  interactive: 2,
  complete: 3
};

class PageObserver {
  stage = PageStage.initial;
  started = false;
  constructor(delegate) {
    this.delegate = delegate;
  }
  start() {
    if (!this.started) {
      if (this.stage == PageStage.initial) {
        this.stage = PageStage.loading;
      }
      document.addEventListener("readystatechange", this.interpretReadyState, false);
      addEventListener("pagehide", this.pageWillUnload, false);
      this.started = true;
    }
  }
  stop() {
    if (this.started) {
      document.removeEventListener("readystatechange", this.interpretReadyState, false);
      removeEventListener("pagehide", this.pageWillUnload, false);
      this.started = false;
    }
  }
  interpretReadyState = () => {
    const { readyState } = this;
    if (readyState == "interactive") {
      this.pageIsInteractive();
    } else if (readyState == "complete") {
      this.pageIsComplete();
    }
  };
  pageIsInteractive() {
    if (this.stage == PageStage.loading) {
      this.stage = PageStage.interactive;
      this.delegate.pageBecameInteractive();
    }
  }
  pageIsComplete() {
    this.pageIsInteractive();
    if (this.stage == PageStage.interactive) {
      this.stage = PageStage.complete;
      this.delegate.pageLoaded();
    }
  }
  pageWillUnload = () => {
    this.delegate.pageWillUnload();
  };
  get readyState() {
    return document.readyState;
  }
}

class ScrollObserver {
  started = false;
  constructor(delegate) {
    this.delegate = delegate;
  }
  start() {
    if (!this.started) {
      addEventListener("scroll", this.onScroll, false);
      this.onScroll();
      this.started = true;
    }
  }
  stop() {
    if (this.started) {
      removeEventListener("scroll", this.onScroll, false);
      this.started = false;
    }
  }
  onScroll = () => {
    this.updatePosition({ x: window.pageXOffset, y: window.pageYOffset });
  };
  updatePosition(position) {
    this.delegate.scrollPositionChanged(position);
  }
}

class StreamMessageRenderer {
  render({ fragment }) {
    Bardo.preservingPermanentElements(this, getPermanentElementMapForFragment(fragment), () => {
      withAutofocusFromFragment(fragment, () => {
        withPreservedFocus(() => {
          document.documentElement.appendChild(fragment);
        });
      });
    });
  }
  enteringBardo(currentPermanentElement, newPermanentElement) {
    newPermanentElement.replaceWith(currentPermanentElement.cloneNode(true));
  }
  leavingBardo() {
  }
}
function getPermanentElementMapForFragment(fragment) {
  const permanentElementsInDocument = queryPermanentElementsAll(document.documentElement);
  const permanentElementMap = {};
  for (const permanentElementInDocument of permanentElementsInDocument) {
    const { id } = permanentElementInDocument;
    for (const streamElement of fragment.querySelectorAll("turbo-stream")) {
      const elementInStream = getPermanentElementById(streamElement.templateElement.content, id);
      if (elementInStream) {
        permanentElementMap[id] = [permanentElementInDocument, elementInStream];
      }
    }
  }
  return permanentElementMap;
}
async function withAutofocusFromFragment(fragment, callback) {
  const generatedID = `turbo-stream-autofocus-${uuid()}`;
  const turboStreams = fragment.querySelectorAll("turbo-stream");
  const elementWithAutofocus = firstAutofocusableElementInStreams(turboStreams);
  let willAutofocusId = null;
  if (elementWithAutofocus) {
    if (elementWithAutofocus.id) {
      willAutofocusId = elementWithAutofocus.id;
    } else {
      willAutofocusId = generatedID;
    }
    elementWithAutofocus.id = willAutofocusId;
  }
  callback();
  await nextRepaint();
  const hasNoActiveElement = document.activeElement == null || document.activeElement == document.body;
  if (hasNoActiveElement && willAutofocusId) {
    const elementToAutofocus = document.getElementById(willAutofocusId);
    if (elementIsFocusable(elementToAutofocus)) {
      elementToAutofocus.focus();
    }
    if (elementToAutofocus && elementToAutofocus.id == generatedID) {
      elementToAutofocus.removeAttribute("id");
    }
  }
}
async function withPreservedFocus(callback) {
  const [activeElementBeforeRender, activeElementAfterRender] = await around(callback, () => document.activeElement);
  const restoreFocusTo = activeElementBeforeRender && activeElementBeforeRender.id;
  if (restoreFocusTo) {
    const elementToFocus = document.getElementById(restoreFocusTo);
    if (elementIsFocusable(elementToFocus) && elementToFocus != activeElementAfterRender) {
      elementToFocus.focus();
    }
  }
}
function firstAutofocusableElementInStreams(nodeListOfStreamElements) {
  for (const streamElement of nodeListOfStreamElements) {
    const elementWithAutofocus = queryAutofocusableElement(streamElement.templateElement.content);
    if (elementWithAutofocus)
      return elementWithAutofocus;
  }
  return null;
}

class StreamObserver {
  sources = new Set;
  #started = false;
  constructor(delegate) {
    this.delegate = delegate;
  }
  start() {
    if (!this.#started) {
      this.#started = true;
      addEventListener("turbo:before-fetch-response", this.inspectFetchResponse, false);
    }
  }
  stop() {
    if (this.#started) {
      this.#started = false;
      removeEventListener("turbo:before-fetch-response", this.inspectFetchResponse, false);
    }
  }
  connectStreamSource(source) {
    if (!this.streamSourceIsConnected(source)) {
      this.sources.add(source);
      source.addEventListener("message", this.receiveMessageEvent, false);
    }
  }
  disconnectStreamSource(source) {
    if (this.streamSourceIsConnected(source)) {
      this.sources.delete(source);
      source.removeEventListener("message", this.receiveMessageEvent, false);
    }
  }
  streamSourceIsConnected(source) {
    return this.sources.has(source);
  }
  inspectFetchResponse = (event) => {
    const response = fetchResponseFromEvent(event);
    if (response && fetchResponseIsStream(response)) {
      event.preventDefault();
      this.receiveMessageResponse(response);
    }
  };
  receiveMessageEvent = (event) => {
    if (this.#started && typeof event.data == "string") {
      this.receiveMessageHTML(event.data);
    }
  };
  async receiveMessageResponse(response) {
    const html = await response.responseHTML;
    if (html) {
      this.receiveMessageHTML(html);
    }
  }
  receiveMessageHTML(html) {
    this.delegate.receivedMessageFromStream(StreamMessage.wrap(html));
  }
}
function fetchResponseFromEvent(event) {
  const fetchResponse = event.detail?.fetchResponse;
  if (fetchResponse instanceof FetchResponse) {
    return fetchResponse;
  }
}
function fetchResponseIsStream(response) {
  const contentType = response.contentType ?? "";
  return contentType.startsWith(StreamMessage.contentType);
}

class ErrorRenderer extends Renderer {
  static renderElement(currentElement, newElement) {
    const { documentElement, body } = document;
    documentElement.replaceChild(newElement, body);
  }
  async render() {
    this.replaceHeadAndBody();
    this.activateScriptElements();
  }
  replaceHeadAndBody() {
    const { documentElement, head } = document;
    documentElement.replaceChild(this.newHead, head);
    this.renderElement(this.currentElement, this.newElement);
  }
  activateScriptElements() {
    for (const replaceableElement of this.scriptElements) {
      const parentNode = replaceableElement.parentNode;
      if (parentNode) {
        const element = activateScriptElement(replaceableElement);
        parentNode.replaceChild(element, replaceableElement);
      }
    }
  }
  get newHead() {
    return this.newSnapshot.headSnapshot.element;
  }
  get scriptElements() {
    return document.documentElement.querySelectorAll("script");
  }
}

class PageRenderer extends Renderer {
  static renderElement(currentElement, newElement) {
    if (document.body && newElement instanceof HTMLBodyElement) {
      document.body.replaceWith(newElement);
    } else {
      document.documentElement.appendChild(newElement);
    }
  }
  get shouldRender() {
    return this.newSnapshot.isVisitable && this.trackedElementsAreIdentical;
  }
  get reloadReason() {
    if (!this.newSnapshot.isVisitable) {
      return {
        reason: "turbo_visit_control_is_reload"
      };
    }
    if (!this.trackedElementsAreIdentical) {
      return {
        reason: "tracked_element_mismatch"
      };
    }
  }
  async prepareToRender() {
    this.#setLanguage();
    await this.mergeHead();
  }
  async render() {
    if (this.willRender) {
      await this.replaceBody();
    }
  }
  finishRendering() {
    super.finishRendering();
    if (!this.isPreview) {
      this.focusFirstAutofocusableElement();
    }
  }
  get currentHeadSnapshot() {
    return this.currentSnapshot.headSnapshot;
  }
  get newHeadSnapshot() {
    return this.newSnapshot.headSnapshot;
  }
  get newElement() {
    return this.newSnapshot.element;
  }
  #setLanguage() {
    const { documentElement } = this.currentSnapshot;
    const { dir, lang } = this.newSnapshot;
    if (lang) {
      documentElement.setAttribute("lang", lang);
    } else {
      documentElement.removeAttribute("lang");
    }
    if (dir) {
      documentElement.setAttribute("dir", dir);
    } else {
      documentElement.removeAttribute("dir");
    }
  }
  async mergeHead() {
    const mergedHeadElements = this.mergeProvisionalElements();
    const newStylesheetElements = this.copyNewHeadStylesheetElements();
    this.copyNewHeadScriptElements();
    await mergedHeadElements;
    await newStylesheetElements;
    if (this.willRender) {
      this.removeUnusedDynamicStylesheetElements();
    }
  }
  async replaceBody() {
    await this.preservingPermanentElements(async () => {
      this.activateNewBody();
      await this.assignNewBody();
    });
  }
  get trackedElementsAreIdentical() {
    return this.currentHeadSnapshot.trackedElementSignature == this.newHeadSnapshot.trackedElementSignature;
  }
  async copyNewHeadStylesheetElements() {
    const loadingElements = [];
    for (const element of this.newHeadStylesheetElements) {
      loadingElements.push(waitForLoad(element));
      document.head.appendChild(element);
    }
    await Promise.all(loadingElements);
  }
  copyNewHeadScriptElements() {
    for (const element of this.newHeadScriptElements) {
      document.head.appendChild(activateScriptElement(element));
    }
  }
  removeUnusedDynamicStylesheetElements() {
    for (const element of this.unusedDynamicStylesheetElements) {
      document.head.removeChild(element);
    }
  }
  async mergeProvisionalElements() {
    const newHeadElements = [...this.newHeadProvisionalElements];
    for (const element of this.currentHeadProvisionalElements) {
      if (!this.isCurrentElementInElementList(element, newHeadElements)) {
        document.head.removeChild(element);
      }
    }
    for (const element of newHeadElements) {
      document.head.appendChild(element);
    }
  }
  isCurrentElementInElementList(element, elementList) {
    for (const [index, newElement] of elementList.entries()) {
      if (element.tagName == "TITLE") {
        if (newElement.tagName != "TITLE") {
          continue;
        }
        if (element.innerHTML == newElement.innerHTML) {
          elementList.splice(index, 1);
          return true;
        }
      }
      if (newElement.isEqualNode(element)) {
        elementList.splice(index, 1);
        return true;
      }
    }
    return false;
  }
  removeCurrentHeadProvisionalElements() {
    for (const element of this.currentHeadProvisionalElements) {
      document.head.removeChild(element);
    }
  }
  copyNewHeadProvisionalElements() {
    for (const element of this.newHeadProvisionalElements) {
      document.head.appendChild(element);
    }
  }
  activateNewBody() {
    document.adoptNode(this.newElement);
    this.removeNoscriptElements();
    this.activateNewBodyScriptElements();
  }
  removeNoscriptElements() {
    for (const noscriptElement of this.newElement.querySelectorAll("noscript")) {
      noscriptElement.remove();
    }
  }
  activateNewBodyScriptElements() {
    for (const inertScriptElement of this.newBodyScriptElements) {
      const activatedScriptElement = activateScriptElement(inertScriptElement);
      inertScriptElement.replaceWith(activatedScriptElement);
    }
  }
  async assignNewBody() {
    await this.renderElement(this.currentElement, this.newElement);
  }
  get unusedDynamicStylesheetElements() {
    return this.oldHeadStylesheetElements.filter((element) => {
      return element.getAttribute("data-turbo-track") === "dynamic";
    });
  }
  get oldHeadStylesheetElements() {
    return this.currentHeadSnapshot.getStylesheetElementsNotInSnapshot(this.newHeadSnapshot);
  }
  get newHeadStylesheetElements() {
    return this.newHeadSnapshot.getStylesheetElementsNotInSnapshot(this.currentHeadSnapshot);
  }
  get newHeadScriptElements() {
    return this.newHeadSnapshot.getScriptElementsNotInSnapshot(this.currentHeadSnapshot);
  }
  get currentHeadProvisionalElements() {
    return this.currentHeadSnapshot.provisionalElements;
  }
  get newHeadProvisionalElements() {
    return this.newHeadSnapshot.provisionalElements;
  }
  get newBodyScriptElements() {
    return this.newElement.querySelectorAll("script");
  }
}

class MorphingPageRenderer extends PageRenderer {
  static renderElement(currentElement, newElement) {
    morphElements(currentElement, newElement, {
      callbacks: {
        beforeNodeMorphed: (node, newNode) => {
          if (shouldRefreshFrameWithMorphing(node, newNode) && !closestFrameReloadableWithMorphing(node)) {
            node.reload();
            return false;
          }
          return true;
        }
      }
    });
    dispatch("turbo:morph", { detail: { currentElement, newElement } });
  }
  async preservingPermanentElements(callback) {
    return await callback();
  }
  get renderMethod() {
    return "morph";
  }
  get shouldAutofocus() {
    return false;
  }
}

class SnapshotCache extends LRUCache {
  constructor(size) {
    super(size, toCacheKey);
  }
  get snapshots() {
    return this.entries;
  }
}

class PageView extends View {
  snapshotCache = new SnapshotCache(10);
  lastRenderedLocation = new URL(location.href);
  forceReloaded = false;
  shouldTransitionTo(newSnapshot) {
    return this.snapshot.prefersViewTransitions && newSnapshot.prefersViewTransitions;
  }
  renderPage(snapshot, isPreview = false, willRender = true, visit) {
    const shouldMorphPage = this.isPageRefresh(visit) && (visit?.refresh?.method || this.snapshot.refreshMethod) === "morph";
    const rendererClass = shouldMorphPage ? MorphingPageRenderer : PageRenderer;
    const renderer = new rendererClass(this.snapshot, snapshot, isPreview, willRender);
    if (!renderer.shouldRender) {
      this.forceReloaded = true;
    } else {
      visit?.changeHistory();
    }
    return this.render(renderer);
  }
  renderError(snapshot, visit) {
    visit?.changeHistory();
    const renderer = new ErrorRenderer(this.snapshot, snapshot, false);
    return this.render(renderer);
  }
  clearSnapshotCache() {
    this.snapshotCache.clear();
  }
  async cacheSnapshot(snapshot = this.snapshot) {
    if (snapshot.isCacheable) {
      this.delegate.viewWillCacheSnapshot();
      const { lastRenderedLocation: location2 } = this;
      await nextEventLoopTick();
      const cachedSnapshot = snapshot.clone();
      this.snapshotCache.put(location2, cachedSnapshot);
      return cachedSnapshot;
    }
  }
  getCachedSnapshotForLocation(location2) {
    return this.snapshotCache.get(location2);
  }
  isPageRefresh(visit) {
    return !visit || this.lastRenderedLocation.pathname === visit.location.pathname && visit.action === "replace";
  }
  shouldPreserveScrollPosition(visit) {
    return this.isPageRefresh(visit) && (visit?.refresh?.scroll || this.snapshot.refreshScroll) === "preserve";
  }
  get snapshot() {
    return PageSnapshot.fromElement(this.element);
  }
}

class Preloader {
  selector = "a[data-turbo-preload]";
  constructor(delegate, snapshotCache) {
    this.delegate = delegate;
    this.snapshotCache = snapshotCache;
  }
  start() {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", this.#preloadAll);
    } else {
      this.preloadOnLoadLinksForView(document.body);
    }
  }
  stop() {
    document.removeEventListener("DOMContentLoaded", this.#preloadAll);
  }
  preloadOnLoadLinksForView(element) {
    for (const link of element.querySelectorAll(this.selector)) {
      if (this.delegate.shouldPreloadLink(link)) {
        this.preloadURL(link);
      }
    }
  }
  async preloadURL(link) {
    const location2 = new URL(link.href);
    if (this.snapshotCache.has(location2)) {
      return;
    }
    const fetchRequest = new FetchRequest(this, FetchMethod.get, location2, new URLSearchParams, link);
    await fetchRequest.perform();
  }
  prepareRequest(fetchRequest) {
    fetchRequest.headers["X-Sec-Purpose"] = "prefetch";
  }
  async requestSucceededWithResponse(fetchRequest, fetchResponse) {
    try {
      const responseHTML = await fetchResponse.responseHTML;
      const snapshot = PageSnapshot.fromHTMLString(responseHTML);
      this.snapshotCache.put(fetchRequest.url, snapshot);
    } catch (_) {
    }
  }
  requestStarted(fetchRequest) {
  }
  requestErrored(fetchRequest) {
  }
  requestFinished(fetchRequest) {
  }
  requestPreventedHandlingResponse(fetchRequest, fetchResponse) {
  }
  requestFailedWithResponse(fetchRequest, fetchResponse) {
  }
  #preloadAll = () => {
    this.preloadOnLoadLinksForView(document.body);
  };
}

class Cache {
  constructor(session) {
    this.session = session;
  }
  clear() {
    this.session.clearCache();
  }
  resetCacheControl() {
    this.#setCacheControl("");
  }
  exemptPageFromCache() {
    this.#setCacheControl("no-cache");
  }
  exemptPageFromPreview() {
    this.#setCacheControl("no-preview");
  }
  #setCacheControl(value) {
    setMetaContent("turbo-cache-control", value);
  }
}

class Session {
  navigator = new Navigator(this);
  history = new History(this);
  view = new PageView(this, document.documentElement);
  adapter = new BrowserAdapter(this);
  pageObserver = new PageObserver(this);
  cacheObserver = new CacheObserver;
  linkPrefetchObserver = new LinkPrefetchObserver(this, document);
  linkClickObserver = new LinkClickObserver(this, window);
  formSubmitObserver = new FormSubmitObserver(this, document);
  scrollObserver = new ScrollObserver(this);
  streamObserver = new StreamObserver(this);
  formLinkClickObserver = new FormLinkClickObserver(this, document.documentElement);
  frameRedirector = new FrameRedirector(this, document.documentElement);
  streamMessageRenderer = new StreamMessageRenderer;
  cache = new Cache(this);
  enabled = true;
  started = false;
  #pageRefreshDebouncePeriod = 150;
  constructor(recentRequests2) {
    this.recentRequests = recentRequests2;
    this.preloader = new Preloader(this, this.view.snapshotCache);
    this.debouncedRefresh = this.refresh;
    this.pageRefreshDebouncePeriod = this.pageRefreshDebouncePeriod;
  }
  start() {
    if (!this.started) {
      this.pageObserver.start();
      this.cacheObserver.start();
      this.linkPrefetchObserver.start();
      this.formLinkClickObserver.start();
      this.linkClickObserver.start();
      this.formSubmitObserver.start();
      this.scrollObserver.start();
      this.streamObserver.start();
      this.frameRedirector.start();
      this.history.start();
      this.preloader.start();
      this.started = true;
      this.enabled = true;
    }
  }
  disable() {
    this.enabled = false;
  }
  stop() {
    if (this.started) {
      this.pageObserver.stop();
      this.cacheObserver.stop();
      this.linkPrefetchObserver.stop();
      this.formLinkClickObserver.stop();
      this.linkClickObserver.stop();
      this.formSubmitObserver.stop();
      this.scrollObserver.stop();
      this.streamObserver.stop();
      this.frameRedirector.stop();
      this.history.stop();
      this.preloader.stop();
      this.started = false;
    }
  }
  registerAdapter(adapter) {
    this.adapter = adapter;
  }
  visit(location2, options = {}) {
    const frameElement = options.frame ? document.getElementById(options.frame) : null;
    if (frameElement instanceof FrameElement) {
      const action = options.action || getVisitAction(frameElement);
      frameElement.delegate.proposeVisitIfNavigatedWithAction(frameElement, action);
      frameElement.src = location2.toString();
    } else {
      this.navigator.proposeVisit(expandURL(location2), options);
    }
  }
  refresh(url, options = {}) {
    options = typeof options === "string" ? { requestId: options } : options;
    const { method, requestId, scroll } = options;
    const isRecentRequest = requestId && this.recentRequests.has(requestId);
    const isCurrentUrl = url === document.baseURI;
    if (!isRecentRequest && !this.navigator.currentVisit && isCurrentUrl) {
      this.visit(url, { action: "replace", shouldCacheSnapshot: false, refresh: { method, scroll } });
    }
  }
  connectStreamSource(source) {
    this.streamObserver.connectStreamSource(source);
  }
  disconnectStreamSource(source) {
    this.streamObserver.disconnectStreamSource(source);
  }
  renderStreamMessage(message) {
    this.streamMessageRenderer.render(StreamMessage.wrap(message));
  }
  clearCache() {
    this.view.clearSnapshotCache();
  }
  setProgressBarDelay(delay) {
    console.warn("Please replace `session.setProgressBarDelay(delay)` with `session.progressBarDelay = delay`. The function is deprecated and will be removed in a future version of Turbo.`");
    this.progressBarDelay = delay;
  }
  set progressBarDelay(delay) {
    config.drive.progressBarDelay = delay;
  }
  get progressBarDelay() {
    return config.drive.progressBarDelay;
  }
  set drive(value) {
    config.drive.enabled = value;
  }
  get drive() {
    return config.drive.enabled;
  }
  set formMode(value) {
    config.forms.mode = value;
  }
  get formMode() {
    return config.forms.mode;
  }
  get location() {
    return this.history.location;
  }
  get restorationIdentifier() {
    return this.history.restorationIdentifier;
  }
  get pageRefreshDebouncePeriod() {
    return this.#pageRefreshDebouncePeriod;
  }
  set pageRefreshDebouncePeriod(value) {
    this.refresh = debounce(this.debouncedRefresh.bind(this), value);
    this.#pageRefreshDebouncePeriod = value;
  }
  shouldPreloadLink(element) {
    const isUnsafe = element.hasAttribute("data-turbo-method");
    const isStream = element.hasAttribute("data-turbo-stream");
    const frameTarget = element.getAttribute("data-turbo-frame");
    const frame = frameTarget == "_top" ? null : document.getElementById(frameTarget) || findClosestRecursively(element, "turbo-frame:not([disabled])");
    if (isUnsafe || isStream || frame instanceof FrameElement) {
      return false;
    } else {
      const location2 = new URL(element.href);
      return this.elementIsNavigatable(element) && locationIsVisitable(location2, this.snapshot.rootLocation);
    }
  }
  historyPoppedToLocationWithRestorationIdentifierAndDirection(location2, restorationIdentifier, direction) {
    if (this.enabled) {
      this.navigator.startVisit(location2, restorationIdentifier, {
        action: "restore",
        historyChanged: true,
        direction
      });
    } else {
      this.adapter.pageInvalidated({
        reason: "turbo_disabled"
      });
    }
  }
  historyPoppedWithEmptyState(location2) {
    this.history.replace(location2);
    this.view.lastRenderedLocation = location2;
    this.view.cacheSnapshot();
  }
  scrollPositionChanged(position) {
    this.history.updateRestorationData({ scrollPosition: position });
  }
  willSubmitFormLinkToLocation(link, location2) {
    return this.elementIsNavigatable(link) && locationIsVisitable(location2, this.snapshot.rootLocation);
  }
  submittedFormLinkToLocation() {
  }
  canPrefetchRequestToLocation(link, location2) {
    return this.elementIsNavigatable(link) && locationIsVisitable(location2, this.snapshot.rootLocation) && this.navigator.linkPrefetchingIsEnabledForLocation(location2);
  }
  willFollowLinkToLocation(link, location2, event) {
    return this.elementIsNavigatable(link) && locationIsVisitable(location2, this.snapshot.rootLocation) && this.applicationAllowsFollowingLinkToLocation(link, location2, event);
  }
  followedLinkToLocation(link, location2) {
    const action = this.getActionForLink(link);
    const acceptsStreamResponse = link.hasAttribute("data-turbo-stream");
    this.visit(location2.href, { action, acceptsStreamResponse });
  }
  allowsVisitingLocationWithAction(location2, action) {
    return this.applicationAllowsVisitingLocation(location2);
  }
  visitProposedToLocation(location2, options) {
    extendURLWithDeprecatedProperties(location2);
    this.adapter.visitProposedToLocation(location2, options);
  }
  visitStarted(visit) {
    if (!visit.acceptsStreamResponse) {
      markAsBusy(document.documentElement);
      this.view.markVisitDirection(visit.direction);
    }
    extendURLWithDeprecatedProperties(visit.location);
    this.notifyApplicationAfterVisitingLocation(visit.location, visit.action);
  }
  visitCompleted(visit) {
    this.view.unmarkVisitDirection();
    clearBusyState(document.documentElement);
    this.notifyApplicationAfterPageLoad(visit.getTimingMetrics());
  }
  willSubmitForm(form, submitter2) {
    const action = getAction$1(form, submitter2);
    return this.submissionIsNavigatable(form, submitter2) && locationIsVisitable(expandURL(action), this.snapshot.rootLocation);
  }
  formSubmitted(form, submitter2) {
    this.navigator.submitForm(form, submitter2);
  }
  pageBecameInteractive() {
    this.view.lastRenderedLocation = this.location;
    this.notifyApplicationAfterPageLoad();
  }
  pageLoaded() {
    this.history.assumeControlOfScrollRestoration();
  }
  pageWillUnload() {
    this.history.relinquishControlOfScrollRestoration();
  }
  receivedMessageFromStream(message) {
    this.renderStreamMessage(message);
  }
  viewWillCacheSnapshot() {
    this.notifyApplicationBeforeCachingSnapshot();
  }
  allowsImmediateRender({ element }, options) {
    const event = this.notifyApplicationBeforeRender(element, options);
    const {
      defaultPrevented,
      detail: { render }
    } = event;
    if (this.view.renderer && render) {
      this.view.renderer.renderElement = render;
    }
    return !defaultPrevented;
  }
  viewRenderedSnapshot(_snapshot, _isPreview, renderMethod) {
    this.view.lastRenderedLocation = this.history.location;
    this.notifyApplicationAfterRender(renderMethod);
  }
  preloadOnLoadLinksForView(element) {
    this.preloader.preloadOnLoadLinksForView(element);
  }
  viewInvalidated(reason) {
    this.adapter.pageInvalidated(reason);
  }
  frameLoaded(frame) {
    this.notifyApplicationAfterFrameLoad(frame);
  }
  frameRendered(fetchResponse, frame) {
    this.notifyApplicationAfterFrameRender(fetchResponse, frame);
  }
  applicationAllowsFollowingLinkToLocation(link, location2, ev) {
    const event = this.notifyApplicationAfterClickingLinkToLocation(link, location2, ev);
    return !event.defaultPrevented;
  }
  applicationAllowsVisitingLocation(location2) {
    const event = this.notifyApplicationBeforeVisitingLocation(location2);
    return !event.defaultPrevented;
  }
  notifyApplicationAfterClickingLinkToLocation(link, location2, event) {
    return dispatch("turbo:click", {
      target: link,
      detail: { url: location2.href, originalEvent: event },
      cancelable: true
    });
  }
  notifyApplicationBeforeVisitingLocation(location2) {
    return dispatch("turbo:before-visit", {
      detail: { url: location2.href },
      cancelable: true
    });
  }
  notifyApplicationAfterVisitingLocation(location2, action) {
    return dispatch("turbo:visit", { detail: { url: location2.href, action } });
  }
  notifyApplicationBeforeCachingSnapshot() {
    return dispatch("turbo:before-cache");
  }
  notifyApplicationBeforeRender(newBody, options) {
    return dispatch("turbo:before-render", {
      detail: { newBody, ...options },
      cancelable: true
    });
  }
  notifyApplicationAfterRender(renderMethod) {
    return dispatch("turbo:render", { detail: { renderMethod } });
  }
  notifyApplicationAfterPageLoad(timing = {}) {
    return dispatch("turbo:load", {
      detail: { url: this.location.href, timing }
    });
  }
  notifyApplicationAfterFrameLoad(frame) {
    return dispatch("turbo:frame-load", { target: frame });
  }
  notifyApplicationAfterFrameRender(fetchResponse, frame) {
    return dispatch("turbo:frame-render", {
      detail: { fetchResponse },
      target: frame,
      cancelable: true
    });
  }
  submissionIsNavigatable(form, submitter2) {
    if (config.forms.mode == "off") {
      return false;
    } else {
      const submitterIsNavigatable = submitter2 ? this.elementIsNavigatable(submitter2) : true;
      if (config.forms.mode == "optin") {
        return submitterIsNavigatable && form.closest('[data-turbo="true"]') != null;
      } else {
        return submitterIsNavigatable && this.elementIsNavigatable(form);
      }
    }
  }
  elementIsNavigatable(element) {
    const container = findClosestRecursively(element, "[data-turbo]");
    const withinFrame = findClosestRecursively(element, "turbo-frame");
    if (config.drive.enabled || withinFrame) {
      if (container) {
        return container.getAttribute("data-turbo") != "false";
      } else {
        return true;
      }
    } else {
      if (container) {
        return container.getAttribute("data-turbo") == "true";
      } else {
        return false;
      }
    }
  }
  getActionForLink(link) {
    return getVisitAction(link) || "advance";
  }
  get snapshot() {
    return this.view.snapshot;
  }
}
function extendURLWithDeprecatedProperties(url) {
  Object.defineProperties(url, deprecatedLocationPropertyDescriptors);
}
var deprecatedLocationPropertyDescriptors = {
  absoluteURL: {
    get() {
      return this.toString();
    }
  }
};
var session = new Session(recentRequests);
var { cache, navigator: sessionNavigator } = session;
function start() {
  session.start();
}
function registerAdapter(adapter) {
  session.registerAdapter(adapter);
}
function visit(location2, options) {
  session.visit(location2, options);
}
function connectStreamSource(source) {
  session.connectStreamSource(source);
}
function disconnectStreamSource(source) {
  session.disconnectStreamSource(source);
}
function renderStreamMessage(message) {
  session.renderStreamMessage(message);
}
function setProgressBarDelay(delay) {
  console.warn("Please replace `Turbo.setProgressBarDelay(delay)` with `Turbo.config.drive.progressBarDelay = delay`. The top-level function is deprecated and will be removed in a future version of Turbo.`");
  config.drive.progressBarDelay = delay;
}
function setConfirmMethod(confirmMethod) {
  console.warn("Please replace `Turbo.setConfirmMethod(confirmMethod)` with `Turbo.config.forms.confirm = confirmMethod`. The top-level function is deprecated and will be removed in a future version of Turbo.`");
  config.forms.confirm = confirmMethod;
}
function setFormMode(mode) {
  console.warn("Please replace `Turbo.setFormMode(mode)` with `Turbo.config.forms.mode = mode`. The top-level function is deprecated and will be removed in a future version of Turbo.`");
  config.forms.mode = mode;
}
function morphBodyElements(currentBody, newBody) {
  MorphingPageRenderer.renderElement(currentBody, newBody);
}
function morphTurboFrameElements(currentFrame, newFrame) {
  MorphingFrameRenderer.renderElement(currentFrame, newFrame);
}
var Turbo = /* @__PURE__ */ Object.freeze({
  __proto__: null,
  PageRenderer,
  PageSnapshot,
  FrameRenderer,
  fetch: fetchWithTurboHeaders,
  config,
  session,
  cache,
  navigator: sessionNavigator,
  start,
  registerAdapter,
  visit,
  connectStreamSource,
  disconnectStreamSource,
  renderStreamMessage,
  setProgressBarDelay,
  setConfirmMethod,
  setFormMode,
  morphBodyElements,
  morphTurboFrameElements,
  morphChildren,
  morphElements
});

class TurboFrameMissingError extends Error {
}

class FrameController {
  fetchResponseLoaded = (_fetchResponse) => Promise.resolve();
  #currentFetchRequest = null;
  #resolveVisitPromise = () => {
  };
  #connected = false;
  #hasBeenLoaded = false;
  #ignoredAttributes = new Set;
  #shouldMorphFrame = false;
  action = null;
  constructor(element) {
    this.element = element;
    this.view = new FrameView(this, this.element);
    this.appearanceObserver = new AppearanceObserver(this, this.element);
    this.formLinkClickObserver = new FormLinkClickObserver(this, this.element);
    this.linkInterceptor = new LinkInterceptor(this, this.element);
    this.restorationIdentifier = uuid();
    this.formSubmitObserver = new FormSubmitObserver(this, this.element);
  }
  connect() {
    if (!this.#connected) {
      this.#connected = true;
      if (this.loadingStyle == FrameLoadingStyle.lazy) {
        this.appearanceObserver.start();
      } else {
        this.#loadSourceURL();
      }
      this.formLinkClickObserver.start();
      this.linkInterceptor.start();
      this.formSubmitObserver.start();
    }
  }
  disconnect() {
    if (this.#connected) {
      this.#connected = false;
      this.appearanceObserver.stop();
      this.formLinkClickObserver.stop();
      this.linkInterceptor.stop();
      this.formSubmitObserver.stop();
      if (!this.element.hasAttribute("recurse")) {
        this.#currentFetchRequest?.cancel();
      }
    }
  }
  disabledChanged() {
    if (this.disabled) {
      this.#currentFetchRequest?.cancel();
    } else if (this.loadingStyle == FrameLoadingStyle.eager) {
      this.#loadSourceURL();
    }
  }
  sourceURLChanged() {
    if (this.#isIgnoringChangesTo("src"))
      return;
    if (!this.sourceURL) {
      this.#currentFetchRequest?.cancel();
    }
    if (this.element.isConnected) {
      this.complete = false;
    }
    if (this.loadingStyle == FrameLoadingStyle.eager || this.#hasBeenLoaded) {
      this.#loadSourceURL();
    }
  }
  sourceURLReloaded() {
    const { refresh, src } = this.element;
    this.#shouldMorphFrame = src && refresh === "morph";
    this.element.removeAttribute("complete");
    this.element.src = null;
    this.element.src = src;
    return this.element.loaded;
  }
  loadingStyleChanged() {
    if (this.loadingStyle == FrameLoadingStyle.lazy) {
      this.appearanceObserver.start();
    } else {
      this.appearanceObserver.stop();
      this.#loadSourceURL();
    }
  }
  async#loadSourceURL() {
    if (this.enabled && this.isActive && !this.complete && this.sourceURL) {
      this.element.loaded = this.#visit(expandURL(this.sourceURL));
      this.appearanceObserver.stop();
      await this.element.loaded;
      this.#hasBeenLoaded = true;
    }
  }
  async loadResponse(fetchResponse) {
    if (fetchResponse.redirected || fetchResponse.succeeded && fetchResponse.isHTML) {
      this.sourceURL = fetchResponse.response.url;
    }
    try {
      const html = await fetchResponse.responseHTML;
      if (html) {
        const document2 = parseHTMLDocument(html);
        const pageSnapshot = PageSnapshot.fromDocument(document2);
        if (pageSnapshot.isVisitable) {
          await this.#loadFrameResponse(fetchResponse, document2);
        } else {
          await this.#handleUnvisitableFrameResponse(fetchResponse);
        }
      }
    } finally {
      this.#shouldMorphFrame = false;
      this.fetchResponseLoaded = () => Promise.resolve();
    }
  }
  elementAppearedInViewport(element) {
    this.proposeVisitIfNavigatedWithAction(element, getVisitAction(element));
    this.#loadSourceURL();
  }
  willSubmitFormLinkToLocation(link) {
    return this.#shouldInterceptNavigation(link);
  }
  submittedFormLinkToLocation(link, _location, form) {
    const frame = this.#findFrameElement(link);
    if (frame)
      form.setAttribute("data-turbo-frame", frame.id);
  }
  shouldInterceptLinkClick(element, _location, _event) {
    return this.#shouldInterceptNavigation(element);
  }
  linkClickIntercepted(element, location2) {
    this.#navigateFrame(element, location2);
  }
  willSubmitForm(element, submitter2) {
    return element.closest("turbo-frame") == this.element && this.#shouldInterceptNavigation(element, submitter2);
  }
  formSubmitted(element, submitter2) {
    if (this.formSubmission) {
      this.formSubmission.stop();
    }
    this.formSubmission = new FormSubmission(this, element, submitter2);
    const { fetchRequest } = this.formSubmission;
    const frame = this.#findFrameElement(element, submitter2);
    this.prepareRequest(fetchRequest, frame);
    this.formSubmission.start();
  }
  prepareRequest(request, frame = this) {
    request.headers["Turbo-Frame"] = frame.id;
    if (this.currentNavigationElement?.hasAttribute("data-turbo-stream")) {
      request.acceptResponseType(StreamMessage.contentType);
    }
  }
  requestStarted(_request) {
    markAsBusy(this.element);
  }
  requestPreventedHandlingResponse(_request, _response) {
    this.#resolveVisitPromise();
  }
  async requestSucceededWithResponse(request, response) {
    await this.loadResponse(response);
    this.#resolveVisitPromise();
  }
  async requestFailedWithResponse(request, response) {
    await this.loadResponse(response);
    this.#resolveVisitPromise();
  }
  requestErrored(request, error) {
    console.error(error);
    this.#resolveVisitPromise();
  }
  requestFinished(_request) {
    clearBusyState(this.element);
  }
  formSubmissionStarted({ formElement }) {
    markAsBusy(formElement, this.#findFrameElement(formElement));
  }
  formSubmissionSucceededWithResponse(formSubmission, response) {
    const frame = this.#findFrameElement(formSubmission.formElement, formSubmission.submitter);
    frame.delegate.proposeVisitIfNavigatedWithAction(frame, getVisitAction(formSubmission.submitter, formSubmission.formElement, frame));
    frame.delegate.loadResponse(response);
    if (!formSubmission.isSafe) {
      session.clearCache();
    }
  }
  formSubmissionFailedWithResponse(formSubmission, fetchResponse) {
    this.element.delegate.loadResponse(fetchResponse);
    session.clearCache();
  }
  formSubmissionErrored(formSubmission, error) {
    console.error(error);
  }
  formSubmissionFinished({ formElement }) {
    clearBusyState(formElement, this.#findFrameElement(formElement));
  }
  allowsImmediateRender({ element: newFrame }, options) {
    const event = dispatch("turbo:before-frame-render", {
      target: this.element,
      detail: { newFrame, ...options },
      cancelable: true
    });
    const {
      defaultPrevented,
      detail: { render }
    } = event;
    if (this.view.renderer && render) {
      this.view.renderer.renderElement = render;
    }
    return !defaultPrevented;
  }
  viewRenderedSnapshot(_snapshot, _isPreview, _renderMethod) {
  }
  preloadOnLoadLinksForView(element) {
    session.preloadOnLoadLinksForView(element);
  }
  viewInvalidated() {
  }
  willRenderFrame(currentElement, _newElement) {
    this.previousFrameElement = currentElement.cloneNode(true);
  }
  visitCachedSnapshot = ({ element }) => {
    const frame = element.querySelector("#" + this.element.id);
    if (frame && this.previousFrameElement) {
      frame.replaceChildren(...this.previousFrameElement.children);
    }
    delete this.previousFrameElement;
  };
  async#loadFrameResponse(fetchResponse, document2) {
    const newFrameElement = await this.extractForeignFrameElement(document2.body);
    const rendererClass = this.#shouldMorphFrame ? MorphingFrameRenderer : FrameRenderer;
    if (newFrameElement) {
      const snapshot = new Snapshot(newFrameElement);
      const renderer = new rendererClass(this, this.view.snapshot, snapshot, false, false);
      if (this.view.renderPromise)
        await this.view.renderPromise;
      this.changeHistory();
      await this.view.render(renderer);
      this.complete = true;
      session.frameRendered(fetchResponse, this.element);
      session.frameLoaded(this.element);
      await this.fetchResponseLoaded(fetchResponse);
    } else if (this.#willHandleFrameMissingFromResponse(fetchResponse)) {
      this.#handleFrameMissingFromResponse(fetchResponse);
    }
  }
  async#visit(url) {
    const request = new FetchRequest(this, FetchMethod.get, url, new URLSearchParams, this.element);
    this.#currentFetchRequest?.cancel();
    this.#currentFetchRequest = request;
    return new Promise((resolve) => {
      this.#resolveVisitPromise = () => {
        this.#resolveVisitPromise = () => {
        };
        this.#currentFetchRequest = null;
        resolve();
      };
      request.perform();
    });
  }
  #navigateFrame(element, url, submitter2) {
    const frame = this.#findFrameElement(element, submitter2);
    frame.delegate.proposeVisitIfNavigatedWithAction(frame, getVisitAction(submitter2, element, frame));
    this.#withCurrentNavigationElement(element, () => {
      frame.src = url;
    });
  }
  proposeVisitIfNavigatedWithAction(frame, action = null) {
    this.action = action;
    if (this.action) {
      const pageSnapshot = PageSnapshot.fromElement(frame).clone();
      const { visitCachedSnapshot } = frame.delegate;
      frame.delegate.fetchResponseLoaded = async (fetchResponse) => {
        if (frame.src) {
          const { statusCode, redirected } = fetchResponse;
          const responseHTML = await fetchResponse.responseHTML;
          const response = { statusCode, redirected, responseHTML };
          const options = {
            response,
            visitCachedSnapshot,
            willRender: false,
            updateHistory: false,
            restorationIdentifier: this.restorationIdentifier,
            snapshot: pageSnapshot
          };
          if (this.action)
            options.action = this.action;
          session.visit(frame.src, options);
        }
      };
    }
  }
  changeHistory() {
    if (this.action) {
      const method = getHistoryMethodForAction(this.action);
      session.history.update(method, expandURL(this.element.src || ""), this.restorationIdentifier);
    }
  }
  async#handleUnvisitableFrameResponse(fetchResponse) {
    console.warn(`The response (${fetchResponse.statusCode}) from <turbo-frame id="${this.element.id}"> is performing a full page visit due to turbo-visit-control.`);
    await this.#visitResponse(fetchResponse.response);
  }
  #willHandleFrameMissingFromResponse(fetchResponse) {
    this.element.setAttribute("complete", "");
    const response = fetchResponse.response;
    const visit2 = async (url, options) => {
      if (url instanceof Response) {
        this.#visitResponse(url);
      } else {
        session.visit(url, options);
      }
    };
    const event = dispatch("turbo:frame-missing", {
      target: this.element,
      detail: { response, visit: visit2 },
      cancelable: true
    });
    return !event.defaultPrevented;
  }
  #handleFrameMissingFromResponse(fetchResponse) {
    this.view.missing();
    this.#throwFrameMissingError(fetchResponse);
  }
  #throwFrameMissingError(fetchResponse) {
    const message = `The response (${fetchResponse.statusCode}) did not contain the expected <turbo-frame id="${this.element.id}"> and will be ignored. To perform a full page visit instead, set turbo-visit-control to reload.`;
    throw new TurboFrameMissingError(message);
  }
  async#visitResponse(response) {
    const wrapped = new FetchResponse(response);
    const responseHTML = await wrapped.responseHTML;
    const { location: location2, redirected, statusCode } = wrapped;
    return session.visit(location2, { response: { redirected, statusCode, responseHTML } });
  }
  #findFrameElement(element, submitter2) {
    const id = getAttribute("data-turbo-frame", submitter2, element) || this.element.getAttribute("target");
    const target = this.#getFrameElementById(id);
    return target instanceof FrameElement ? target : this.element;
  }
  async extractForeignFrameElement(container) {
    let element;
    const id = CSS.escape(this.id);
    try {
      element = activateElement(container.querySelector(`turbo-frame#${id}`), this.sourceURL);
      if (element) {
        return element;
      }
      element = activateElement(container.querySelector(`turbo-frame[src][recurse~=${id}]`), this.sourceURL);
      if (element) {
        await element.loaded;
        return await this.extractForeignFrameElement(element);
      }
    } catch (error) {
      console.error(error);
      return new FrameElement;
    }
    return null;
  }
  #formActionIsVisitable(form, submitter2) {
    const action = getAction$1(form, submitter2);
    return locationIsVisitable(expandURL(action), this.rootLocation);
  }
  #shouldInterceptNavigation(element, submitter2) {
    const id = getAttribute("data-turbo-frame", submitter2, element) || this.element.getAttribute("target");
    if (element instanceof HTMLFormElement && !this.#formActionIsVisitable(element, submitter2)) {
      return false;
    }
    if (!this.enabled || id == "_top") {
      return false;
    }
    if (id) {
      const frameElement = this.#getFrameElementById(id);
      if (frameElement) {
        return !frameElement.disabled;
      } else if (id == "_parent") {
        return false;
      }
    }
    if (!session.elementIsNavigatable(element)) {
      return false;
    }
    if (submitter2 && !session.elementIsNavigatable(submitter2)) {
      return false;
    }
    return true;
  }
  get id() {
    return this.element.id;
  }
  get disabled() {
    return this.element.disabled;
  }
  get enabled() {
    return !this.disabled;
  }
  get sourceURL() {
    if (this.element.src) {
      return this.element.src;
    }
  }
  set sourceURL(sourceURL) {
    this.#ignoringChangesToAttribute("src", () => {
      this.element.src = sourceURL ?? null;
    });
  }
  get loadingStyle() {
    return this.element.loading;
  }
  get isLoading() {
    return this.formSubmission !== undefined || this.#resolveVisitPromise() !== undefined;
  }
  get complete() {
    return this.element.hasAttribute("complete");
  }
  set complete(value) {
    if (value) {
      this.element.setAttribute("complete", "");
    } else {
      this.element.removeAttribute("complete");
    }
  }
  get isActive() {
    return this.element.isActive && this.#connected;
  }
  get rootLocation() {
    const meta = this.element.ownerDocument.querySelector(`meta[name="turbo-root"]`);
    const root = meta?.content ?? "/";
    return expandURL(root);
  }
  #isIgnoringChangesTo(attributeName) {
    return this.#ignoredAttributes.has(attributeName);
  }
  #ignoringChangesToAttribute(attributeName, callback) {
    this.#ignoredAttributes.add(attributeName);
    callback();
    this.#ignoredAttributes.delete(attributeName);
  }
  #withCurrentNavigationElement(element, callback) {
    this.currentNavigationElement = element;
    callback();
    delete this.currentNavigationElement;
  }
  #getFrameElementById(id) {
    if (id != null) {
      const element = id === "_parent" ? this.element.parentElement.closest("turbo-frame") : document.getElementById(id);
      if (element instanceof FrameElement) {
        return element;
      }
    }
  }
}
function activateElement(element, currentURL) {
  if (element) {
    const src = element.getAttribute("src");
    if (src != null && currentURL != null && urlsAreEqual(src, currentURL)) {
      throw new Error(`Matching <turbo-frame id="${element.id}"> element has a source URL which references itself`);
    }
    if (element.ownerDocument !== document) {
      element = document.importNode(element, true);
    }
    if (element instanceof FrameElement) {
      element.connectedCallback();
      element.disconnectedCallback();
      return element;
    }
  }
}
var StreamActions = {
  after() {
    this.removeDuplicateTargetSiblings();
    this.targetElements.forEach((e) => e.parentElement?.insertBefore(this.templateContent, e.nextSibling));
  },
  append() {
    this.removeDuplicateTargetChildren();
    this.targetElements.forEach((e) => e.append(this.templateContent));
  },
  before() {
    this.removeDuplicateTargetSiblings();
    this.targetElements.forEach((e) => e.parentElement?.insertBefore(this.templateContent, e));
  },
  prepend() {
    this.removeDuplicateTargetChildren();
    this.targetElements.forEach((e) => e.prepend(this.templateContent));
  },
  remove() {
    this.targetElements.forEach((e) => e.remove());
  },
  replace() {
    const method = this.getAttribute("method");
    this.targetElements.forEach((targetElement) => {
      if (method === "morph") {
        morphElements(targetElement, this.templateContent);
      } else {
        targetElement.replaceWith(this.templateContent);
      }
    });
  },
  update() {
    const method = this.getAttribute("method");
    this.targetElements.forEach((targetElement) => {
      if (method === "morph") {
        morphChildren(targetElement, this.templateContent);
      } else {
        targetElement.innerHTML = "";
        targetElement.append(this.templateContent);
      }
    });
  },
  refresh() {
    const method = this.getAttribute("method");
    const requestId = this.requestId;
    const scroll = this.getAttribute("scroll");
    session.refresh(this.baseURI, { method, requestId, scroll });
  }
};

class StreamElement extends HTMLElement {
  static async renderElement(newElement) {
    await newElement.performAction();
  }
  async connectedCallback() {
    try {
      await this.render();
    } catch (error) {
      console.error(error);
    } finally {
      this.disconnect();
    }
  }
  async render() {
    return this.renderPromise ??= (async () => {
      const event = this.beforeRenderEvent;
      if (this.dispatchEvent(event)) {
        await nextRepaint();
        await event.detail.render(this);
      }
    })();
  }
  disconnect() {
    try {
      this.remove();
    } catch {
    }
  }
  removeDuplicateTargetChildren() {
    this.duplicateChildren.forEach((c) => c.remove());
  }
  get duplicateChildren() {
    const existingChildren = this.targetElements.flatMap((e) => [...e.children]).filter((c) => !!c.getAttribute("id"));
    const newChildrenIds = [...this.templateContent?.children || []].filter((c) => !!c.getAttribute("id")).map((c) => c.getAttribute("id"));
    return existingChildren.filter((c) => newChildrenIds.includes(c.getAttribute("id")));
  }
  removeDuplicateTargetSiblings() {
    this.duplicateSiblings.forEach((c) => c.remove());
  }
  get duplicateSiblings() {
    const existingChildren = this.targetElements.flatMap((e) => [...e.parentElement.children]).filter((c) => !!c.id);
    const newChildrenIds = [...this.templateContent?.children || []].filter((c) => !!c.id).map((c) => c.id);
    return existingChildren.filter((c) => newChildrenIds.includes(c.id));
  }
  get performAction() {
    if (this.action) {
      const actionFunction = StreamActions[this.action];
      if (actionFunction) {
        return actionFunction;
      }
      this.#raise("unknown action");
    }
    this.#raise("action attribute is missing");
  }
  get targetElements() {
    if (this.target) {
      return this.targetElementsById;
    } else if (this.targets) {
      return this.targetElementsByQuery;
    } else {
      this.#raise("target or targets attribute is missing");
    }
  }
  get templateContent() {
    return this.templateElement.content.cloneNode(true);
  }
  get templateElement() {
    if (this.firstElementChild === null) {
      const template = this.ownerDocument.createElement("template");
      this.appendChild(template);
      return template;
    } else if (this.firstElementChild instanceof HTMLTemplateElement) {
      return this.firstElementChild;
    }
    this.#raise("first child element must be a <template> element");
  }
  get action() {
    return this.getAttribute("action");
  }
  get target() {
    return this.getAttribute("target");
  }
  get targets() {
    return this.getAttribute("targets");
  }
  get requestId() {
    return this.getAttribute("request-id");
  }
  #raise(message) {
    throw new Error(`${this.description}: ${message}`);
  }
  get description() {
    return (this.outerHTML.match(/<[^>]+>/) ?? [])[0] ?? "<turbo-stream>";
  }
  get beforeRenderEvent() {
    return new CustomEvent("turbo:before-stream-render", {
      bubbles: true,
      cancelable: true,
      detail: { newStream: this, render: StreamElement.renderElement }
    });
  }
  get targetElementsById() {
    const element = this.ownerDocument?.getElementById(this.target);
    if (element !== null) {
      return [element];
    } else {
      return [];
    }
  }
  get targetElementsByQuery() {
    const elements = this.ownerDocument?.querySelectorAll(this.targets);
    if (elements.length !== 0) {
      return Array.prototype.slice.call(elements);
    } else {
      return [];
    }
  }
}

class StreamSourceElement extends HTMLElement {
  streamSource = null;
  connectedCallback() {
    this.streamSource = this.src.match(/^ws{1,2}:/) ? new WebSocket(this.src) : new EventSource(this.src);
    connectStreamSource(this.streamSource);
  }
  disconnectedCallback() {
    if (this.streamSource) {
      this.streamSource.close();
      disconnectStreamSource(this.streamSource);
    }
  }
  get src() {
    return this.getAttribute("src") || "";
  }
}
FrameElement.delegateConstructor = FrameController;
if (customElements.get("turbo-frame") === undefined) {
  customElements.define("turbo-frame", FrameElement);
}
if (customElements.get("turbo-stream") === undefined) {
  customElements.define("turbo-stream", StreamElement);
}
if (customElements.get("turbo-stream-source") === undefined) {
  customElements.define("turbo-stream-source", StreamSourceElement);
}
(() => {
  const scriptElement = document.currentScript;
  if (!scriptElement)
    return;
  if (scriptElement.hasAttribute("data-turbo-suppress-warning"))
    return;
  let element = scriptElement.parentElement;
  while (element) {
    if (element == document.body) {
      return console.warn(unindent`
        You are loading Turbo from a <script> element inside the <body> element. This is probably not what you meant to do!

        Load your application’s JavaScript bundle inside the <head> element instead. <script> elements in <body> are evaluated with each page change.

        For more information, see: https://turbo.hotwired.dev/handbook/building#working-with-script-elements

        ——
        Suppress this warning by adding a "data-turbo-suppress-warning" attribute to: %s
      `, scriptElement.outerHTML);
    }
    element = element.parentElement;
  }
})();
window.Turbo = { ...Turbo, StreamActions };
start();

// node_modules/@hotwired/turbo-rails/app/javascript/turbo/cable.js
var consumer;
async function getConsumer() {
  return consumer || setConsumer(createConsumer2().then(setConsumer));
}
function setConsumer(newConsumer) {
  return consumer = newConsumer;
}
async function createConsumer2() {
  const { createConsumer: createConsumer3 } = await Promise.resolve().then(() => (init_src(), exports_src));
  return createConsumer3();
}
async function subscribeTo(channel, mixin) {
  const { subscriptions } = await getConsumer();
  return subscriptions.create(channel, mixin);
}

// node_modules/@hotwired/turbo-rails/app/javascript/turbo/snakeize.js
function walk(obj) {
  if (!obj || typeof obj !== "object")
    return obj;
  if (obj instanceof Date || obj instanceof RegExp)
    return obj;
  if (Array.isArray(obj))
    return obj.map(walk);
  return Object.keys(obj).reduce(function(acc, key) {
    var camel = key[0].toLowerCase() + key.slice(1).replace(/([A-Z]+)/g, function(m, x) {
      return "_" + x.toLowerCase();
    });
    acc[camel] = walk(obj[key]);
    return acc;
  }, {});
}

// node_modules/@hotwired/turbo-rails/app/javascript/turbo/cable_stream_source_element.js
class TurboCableStreamSourceElement extends HTMLElement {
  static observedAttributes = ["channel", "signed-stream-name"];
  async connectedCallback() {
    connectStreamSource(this);
    this.subscription = await subscribeTo(this.channel, {
      received: this.dispatchMessageEvent.bind(this),
      connected: this.subscriptionConnected.bind(this),
      disconnected: this.subscriptionDisconnected.bind(this)
    });
  }
  disconnectedCallback() {
    disconnectStreamSource(this);
    if (this.subscription)
      this.subscription.unsubscribe();
    this.subscriptionDisconnected();
  }
  attributeChangedCallback() {
    if (this.subscription) {
      this.disconnectedCallback();
      this.connectedCallback();
    }
  }
  dispatchMessageEvent(data) {
    const event = new MessageEvent("message", { data });
    return this.dispatchEvent(event);
  }
  subscriptionConnected() {
    this.setAttribute("connected", "");
  }
  subscriptionDisconnected() {
    this.removeAttribute("connected");
  }
  get channel() {
    const channel = this.getAttribute("channel");
    const signed_stream_name = this.getAttribute("signed-stream-name");
    return { channel, signed_stream_name, ...walk({ ...this.dataset }) };
  }
}
if (customElements.get("turbo-cable-stream-source") === undefined) {
  customElements.define("turbo-cable-stream-source", TurboCableStreamSourceElement);
}

// node_modules/@hotwired/turbo-rails/app/javascript/turbo/fetch_requests.js
function encodeMethodIntoRequestBody(event) {
  if (event.target instanceof HTMLFormElement) {
    const { target: form, detail: { fetchOptions } } = event;
    form.addEventListener("turbo:submit-start", ({ detail: { formSubmission: { submitter: submitter2 } } }) => {
      const body = isBodyInit(fetchOptions.body) ? fetchOptions.body : new URLSearchParams;
      const method = determineFetchMethod(submitter2, body, form);
      if (!/get/i.test(method)) {
        if (/post/i.test(method)) {
          body.delete("_method");
        } else {
          body.set("_method", method);
        }
        fetchOptions.method = "post";
      }
    }, { once: true });
  }
}
function determineFetchMethod(submitter2, body, form) {
  const formMethod = determineFormMethod(submitter2);
  const overrideMethod = body.get("_method");
  const method = form.getAttribute("method") || "get";
  if (typeof formMethod == "string") {
    return formMethod;
  } else if (typeof overrideMethod == "string") {
    return overrideMethod;
  } else {
    return method;
  }
}
function determineFormMethod(submitter2) {
  if (submitter2 instanceof HTMLButtonElement || submitter2 instanceof HTMLInputElement) {
    if (submitter2.name === "_method") {
      return submitter2.value;
    } else if (submitter2.hasAttribute("formmethod")) {
      return submitter2.formMethod;
    } else {
      return null;
    }
  } else {
    return null;
  }
}
function isBodyInit(body) {
  return body instanceof FormData || body instanceof URLSearchParams;
}

// node_modules/@hotwired/turbo-rails/app/javascript/turbo/index.js
window.Turbo = exports_turbo_es2017_esm;
addEventListener("turbo:before-fetch-request", encodeMethodIntoRequestBody);

// node_modules/@hotwired/stimulus/dist/stimulus.js
class EventListener {
  constructor(eventTarget, eventName, eventOptions) {
    this.eventTarget = eventTarget;
    this.eventName = eventName;
    this.eventOptions = eventOptions;
    this.unorderedBindings = new Set;
  }
  connect() {
    this.eventTarget.addEventListener(this.eventName, this, this.eventOptions);
  }
  disconnect() {
    this.eventTarget.removeEventListener(this.eventName, this, this.eventOptions);
  }
  bindingConnected(binding) {
    this.unorderedBindings.add(binding);
  }
  bindingDisconnected(binding) {
    this.unorderedBindings.delete(binding);
  }
  handleEvent(event) {
    const extendedEvent = extendEvent(event);
    for (const binding of this.bindings) {
      if (extendedEvent.immediatePropagationStopped) {
        break;
      } else {
        binding.handleEvent(extendedEvent);
      }
    }
  }
  hasBindings() {
    return this.unorderedBindings.size > 0;
  }
  get bindings() {
    return Array.from(this.unorderedBindings).sort((left, right) => {
      const leftIndex = left.index, rightIndex = right.index;
      return leftIndex < rightIndex ? -1 : leftIndex > rightIndex ? 1 : 0;
    });
  }
}
function extendEvent(event) {
  if ("immediatePropagationStopped" in event) {
    return event;
  } else {
    const { stopImmediatePropagation } = event;
    return Object.assign(event, {
      immediatePropagationStopped: false,
      stopImmediatePropagation() {
        this.immediatePropagationStopped = true;
        stopImmediatePropagation.call(this);
      }
    });
  }
}

class Dispatcher {
  constructor(application) {
    this.application = application;
    this.eventListenerMaps = new Map;
    this.started = false;
  }
  start() {
    if (!this.started) {
      this.started = true;
      this.eventListeners.forEach((eventListener) => eventListener.connect());
    }
  }
  stop() {
    if (this.started) {
      this.started = false;
      this.eventListeners.forEach((eventListener) => eventListener.disconnect());
    }
  }
  get eventListeners() {
    return Array.from(this.eventListenerMaps.values()).reduce((listeners, map) => listeners.concat(Array.from(map.values())), []);
  }
  bindingConnected(binding) {
    this.fetchEventListenerForBinding(binding).bindingConnected(binding);
  }
  bindingDisconnected(binding, clearEventListeners = false) {
    this.fetchEventListenerForBinding(binding).bindingDisconnected(binding);
    if (clearEventListeners)
      this.clearEventListenersForBinding(binding);
  }
  handleError(error, message, detail = {}) {
    this.application.handleError(error, `Error ${message}`, detail);
  }
  clearEventListenersForBinding(binding) {
    const eventListener = this.fetchEventListenerForBinding(binding);
    if (!eventListener.hasBindings()) {
      eventListener.disconnect();
      this.removeMappedEventListenerFor(binding);
    }
  }
  removeMappedEventListenerFor(binding) {
    const { eventTarget, eventName, eventOptions } = binding;
    const eventListenerMap = this.fetchEventListenerMapForEventTarget(eventTarget);
    const cacheKey = this.cacheKey(eventName, eventOptions);
    eventListenerMap.delete(cacheKey);
    if (eventListenerMap.size == 0)
      this.eventListenerMaps.delete(eventTarget);
  }
  fetchEventListenerForBinding(binding) {
    const { eventTarget, eventName, eventOptions } = binding;
    return this.fetchEventListener(eventTarget, eventName, eventOptions);
  }
  fetchEventListener(eventTarget, eventName, eventOptions) {
    const eventListenerMap = this.fetchEventListenerMapForEventTarget(eventTarget);
    const cacheKey = this.cacheKey(eventName, eventOptions);
    let eventListener = eventListenerMap.get(cacheKey);
    if (!eventListener) {
      eventListener = this.createEventListener(eventTarget, eventName, eventOptions);
      eventListenerMap.set(cacheKey, eventListener);
    }
    return eventListener;
  }
  createEventListener(eventTarget, eventName, eventOptions) {
    const eventListener = new EventListener(eventTarget, eventName, eventOptions);
    if (this.started) {
      eventListener.connect();
    }
    return eventListener;
  }
  fetchEventListenerMapForEventTarget(eventTarget) {
    let eventListenerMap = this.eventListenerMaps.get(eventTarget);
    if (!eventListenerMap) {
      eventListenerMap = new Map;
      this.eventListenerMaps.set(eventTarget, eventListenerMap);
    }
    return eventListenerMap;
  }
  cacheKey(eventName, eventOptions) {
    const parts = [eventName];
    Object.keys(eventOptions).sort().forEach((key) => {
      parts.push(`${eventOptions[key] ? "" : "!"}${key}`);
    });
    return parts.join(":");
  }
}
var defaultActionDescriptorFilters = {
  stop({ event, value }) {
    if (value)
      event.stopPropagation();
    return true;
  },
  prevent({ event, value }) {
    if (value)
      event.preventDefault();
    return true;
  },
  self({ event, value, element }) {
    if (value) {
      return element === event.target;
    } else {
      return true;
    }
  }
};
var descriptorPattern = /^(?:(?:([^.]+?)\+)?(.+?)(?:\.(.+?))?(?:@(window|document))?->)?(.+?)(?:#([^:]+?))(?::(.+))?$/;
function parseActionDescriptorString(descriptorString) {
  const source = descriptorString.trim();
  const matches = source.match(descriptorPattern) || [];
  let eventName = matches[2];
  let keyFilter = matches[3];
  if (keyFilter && !["keydown", "keyup", "keypress"].includes(eventName)) {
    eventName += `.${keyFilter}`;
    keyFilter = "";
  }
  return {
    eventTarget: parseEventTarget(matches[4]),
    eventName,
    eventOptions: matches[7] ? parseEventOptions(matches[7]) : {},
    identifier: matches[5],
    methodName: matches[6],
    keyFilter: matches[1] || keyFilter
  };
}
function parseEventTarget(eventTargetName) {
  if (eventTargetName == "window") {
    return window;
  } else if (eventTargetName == "document") {
    return document;
  }
}
function parseEventOptions(eventOptions) {
  return eventOptions.split(":").reduce((options, token) => Object.assign(options, { [token.replace(/^!/, "")]: !/^!/.test(token) }), {});
}
function stringifyEventTarget(eventTarget) {
  if (eventTarget == window) {
    return "window";
  } else if (eventTarget == document) {
    return "document";
  }
}
function camelize(value) {
  return value.replace(/(?:[_-])([a-z0-9])/g, (_, char) => char.toUpperCase());
}
function namespaceCamelize(value) {
  return camelize(value.replace(/--/g, "-").replace(/__/g, "_"));
}
function capitalize(value) {
  return value.charAt(0).toUpperCase() + value.slice(1);
}
function dasherize(value) {
  return value.replace(/([A-Z])/g, (_, char) => `-${char.toLowerCase()}`);
}
function tokenize(value) {
  return value.match(/[^\s]+/g) || [];
}
function isSomething(object) {
  return object !== null && object !== undefined;
}
function hasProperty(object, property) {
  return Object.prototype.hasOwnProperty.call(object, property);
}
var allModifiers = ["meta", "ctrl", "alt", "shift"];

class Action {
  constructor(element, index, descriptor, schema) {
    this.element = element;
    this.index = index;
    this.eventTarget = descriptor.eventTarget || element;
    this.eventName = descriptor.eventName || getDefaultEventNameForElement(element) || error("missing event name");
    this.eventOptions = descriptor.eventOptions || {};
    this.identifier = descriptor.identifier || error("missing identifier");
    this.methodName = descriptor.methodName || error("missing method name");
    this.keyFilter = descriptor.keyFilter || "";
    this.schema = schema;
  }
  static forToken(token, schema) {
    return new this(token.element, token.index, parseActionDescriptorString(token.content), schema);
  }
  toString() {
    const eventFilter = this.keyFilter ? `.${this.keyFilter}` : "";
    const eventTarget = this.eventTargetName ? `@${this.eventTargetName}` : "";
    return `${this.eventName}${eventFilter}${eventTarget}->${this.identifier}#${this.methodName}`;
  }
  shouldIgnoreKeyboardEvent(event) {
    if (!this.keyFilter) {
      return false;
    }
    const filters = this.keyFilter.split("+");
    if (this.keyFilterDissatisfied(event, filters)) {
      return true;
    }
    const standardFilter = filters.filter((key) => !allModifiers.includes(key))[0];
    if (!standardFilter) {
      return false;
    }
    if (!hasProperty(this.keyMappings, standardFilter)) {
      error(`contains unknown key filter: ${this.keyFilter}`);
    }
    return this.keyMappings[standardFilter].toLowerCase() !== event.key.toLowerCase();
  }
  shouldIgnoreMouseEvent(event) {
    if (!this.keyFilter) {
      return false;
    }
    const filters = [this.keyFilter];
    if (this.keyFilterDissatisfied(event, filters)) {
      return true;
    }
    return false;
  }
  get params() {
    const params = {};
    const pattern = new RegExp(`^data-${this.identifier}-(.+)-param$`, "i");
    for (const { name, value } of Array.from(this.element.attributes)) {
      const match = name.match(pattern);
      const key = match && match[1];
      if (key) {
        params[camelize(key)] = typecast(value);
      }
    }
    return params;
  }
  get eventTargetName() {
    return stringifyEventTarget(this.eventTarget);
  }
  get keyMappings() {
    return this.schema.keyMappings;
  }
  keyFilterDissatisfied(event, filters) {
    const [meta, ctrl, alt, shift] = allModifiers.map((modifier) => filters.includes(modifier));
    return event.metaKey !== meta || event.ctrlKey !== ctrl || event.altKey !== alt || event.shiftKey !== shift;
  }
}
var defaultEventNames = {
  a: () => "click",
  button: () => "click",
  form: () => "submit",
  details: () => "toggle",
  input: (e) => e.getAttribute("type") == "submit" ? "click" : "input",
  select: () => "change",
  textarea: () => "input"
};
function getDefaultEventNameForElement(element) {
  const tagName = element.tagName.toLowerCase();
  if (tagName in defaultEventNames) {
    return defaultEventNames[tagName](element);
  }
}
function error(message) {
  throw new Error(message);
}
function typecast(value) {
  try {
    return JSON.parse(value);
  } catch (o_O) {
    return value;
  }
}

class Binding {
  constructor(context, action) {
    this.context = context;
    this.action = action;
  }
  get index() {
    return this.action.index;
  }
  get eventTarget() {
    return this.action.eventTarget;
  }
  get eventOptions() {
    return this.action.eventOptions;
  }
  get identifier() {
    return this.context.identifier;
  }
  handleEvent(event) {
    const actionEvent = this.prepareActionEvent(event);
    if (this.willBeInvokedByEvent(event) && this.applyEventModifiers(actionEvent)) {
      this.invokeWithEvent(actionEvent);
    }
  }
  get eventName() {
    return this.action.eventName;
  }
  get method() {
    const method = this.controller[this.methodName];
    if (typeof method == "function") {
      return method;
    }
    throw new Error(`Action "${this.action}" references undefined method "${this.methodName}"`);
  }
  applyEventModifiers(event) {
    const { element } = this.action;
    const { actionDescriptorFilters } = this.context.application;
    const { controller } = this.context;
    let passes = true;
    for (const [name, value] of Object.entries(this.eventOptions)) {
      if (name in actionDescriptorFilters) {
        const filter = actionDescriptorFilters[name];
        passes = passes && filter({ name, value, event, element, controller });
      } else {
        continue;
      }
    }
    return passes;
  }
  prepareActionEvent(event) {
    return Object.assign(event, { params: this.action.params });
  }
  invokeWithEvent(event) {
    const { target, currentTarget } = event;
    try {
      this.method.call(this.controller, event);
      this.context.logDebugActivity(this.methodName, { event, target, currentTarget, action: this.methodName });
    } catch (error2) {
      const { identifier, controller, element, index } = this;
      const detail = { identifier, controller, element, index, event };
      this.context.handleError(error2, `invoking action "${this.action}"`, detail);
    }
  }
  willBeInvokedByEvent(event) {
    const eventTarget = event.target;
    if (event instanceof KeyboardEvent && this.action.shouldIgnoreKeyboardEvent(event)) {
      return false;
    }
    if (event instanceof MouseEvent && this.action.shouldIgnoreMouseEvent(event)) {
      return false;
    }
    if (this.element === eventTarget) {
      return true;
    } else if (eventTarget instanceof Element && this.element.contains(eventTarget)) {
      return this.scope.containsElement(eventTarget);
    } else {
      return this.scope.containsElement(this.action.element);
    }
  }
  get controller() {
    return this.context.controller;
  }
  get methodName() {
    return this.action.methodName;
  }
  get element() {
    return this.scope.element;
  }
  get scope() {
    return this.context.scope;
  }
}

class ElementObserver {
  constructor(element, delegate) {
    this.mutationObserverInit = { attributes: true, childList: true, subtree: true };
    this.element = element;
    this.started = false;
    this.delegate = delegate;
    this.elements = new Set;
    this.mutationObserver = new MutationObserver((mutations) => this.processMutations(mutations));
  }
  start() {
    if (!this.started) {
      this.started = true;
      this.mutationObserver.observe(this.element, this.mutationObserverInit);
      this.refresh();
    }
  }
  pause(callback) {
    if (this.started) {
      this.mutationObserver.disconnect();
      this.started = false;
    }
    callback();
    if (!this.started) {
      this.mutationObserver.observe(this.element, this.mutationObserverInit);
      this.started = true;
    }
  }
  stop() {
    if (this.started) {
      this.mutationObserver.takeRecords();
      this.mutationObserver.disconnect();
      this.started = false;
    }
  }
  refresh() {
    if (this.started) {
      const matches = new Set(this.matchElementsInTree());
      for (const element of Array.from(this.elements)) {
        if (!matches.has(element)) {
          this.removeElement(element);
        }
      }
      for (const element of Array.from(matches)) {
        this.addElement(element);
      }
    }
  }
  processMutations(mutations) {
    if (this.started) {
      for (const mutation of mutations) {
        this.processMutation(mutation);
      }
    }
  }
  processMutation(mutation) {
    if (mutation.type == "attributes") {
      this.processAttributeChange(mutation.target, mutation.attributeName);
    } else if (mutation.type == "childList") {
      this.processRemovedNodes(mutation.removedNodes);
      this.processAddedNodes(mutation.addedNodes);
    }
  }
  processAttributeChange(element, attributeName) {
    if (this.elements.has(element)) {
      if (this.delegate.elementAttributeChanged && this.matchElement(element)) {
        this.delegate.elementAttributeChanged(element, attributeName);
      } else {
        this.removeElement(element);
      }
    } else if (this.matchElement(element)) {
      this.addElement(element);
    }
  }
  processRemovedNodes(nodes) {
    for (const node of Array.from(nodes)) {
      const element = this.elementFromNode(node);
      if (element) {
        this.processTree(element, this.removeElement);
      }
    }
  }
  processAddedNodes(nodes) {
    for (const node of Array.from(nodes)) {
      const element = this.elementFromNode(node);
      if (element && this.elementIsActive(element)) {
        this.processTree(element, this.addElement);
      }
    }
  }
  matchElement(element) {
    return this.delegate.matchElement(element);
  }
  matchElementsInTree(tree = this.element) {
    return this.delegate.matchElementsInTree(tree);
  }
  processTree(tree, processor) {
    for (const element of this.matchElementsInTree(tree)) {
      processor.call(this, element);
    }
  }
  elementFromNode(node) {
    if (node.nodeType == Node.ELEMENT_NODE) {
      return node;
    }
  }
  elementIsActive(element) {
    if (element.isConnected != this.element.isConnected) {
      return false;
    } else {
      return this.element.contains(element);
    }
  }
  addElement(element) {
    if (!this.elements.has(element)) {
      if (this.elementIsActive(element)) {
        this.elements.add(element);
        if (this.delegate.elementMatched) {
          this.delegate.elementMatched(element);
        }
      }
    }
  }
  removeElement(element) {
    if (this.elements.has(element)) {
      this.elements.delete(element);
      if (this.delegate.elementUnmatched) {
        this.delegate.elementUnmatched(element);
      }
    }
  }
}

class AttributeObserver {
  constructor(element, attributeName, delegate) {
    this.attributeName = attributeName;
    this.delegate = delegate;
    this.elementObserver = new ElementObserver(element, this);
  }
  get element() {
    return this.elementObserver.element;
  }
  get selector() {
    return `[${this.attributeName}]`;
  }
  start() {
    this.elementObserver.start();
  }
  pause(callback) {
    this.elementObserver.pause(callback);
  }
  stop() {
    this.elementObserver.stop();
  }
  refresh() {
    this.elementObserver.refresh();
  }
  get started() {
    return this.elementObserver.started;
  }
  matchElement(element) {
    return element.hasAttribute(this.attributeName);
  }
  matchElementsInTree(tree) {
    const match = this.matchElement(tree) ? [tree] : [];
    const matches = Array.from(tree.querySelectorAll(this.selector));
    return match.concat(matches);
  }
  elementMatched(element) {
    if (this.delegate.elementMatchedAttribute) {
      this.delegate.elementMatchedAttribute(element, this.attributeName);
    }
  }
  elementUnmatched(element) {
    if (this.delegate.elementUnmatchedAttribute) {
      this.delegate.elementUnmatchedAttribute(element, this.attributeName);
    }
  }
  elementAttributeChanged(element, attributeName) {
    if (this.delegate.elementAttributeValueChanged && this.attributeName == attributeName) {
      this.delegate.elementAttributeValueChanged(element, attributeName);
    }
  }
}
function add(map, key, value) {
  fetch2(map, key).add(value);
}
function del(map, key, value) {
  fetch2(map, key).delete(value);
  prune(map, key);
}
function fetch2(map, key) {
  let values = map.get(key);
  if (!values) {
    values = new Set;
    map.set(key, values);
  }
  return values;
}
function prune(map, key) {
  const values = map.get(key);
  if (values != null && values.size == 0) {
    map.delete(key);
  }
}

class Multimap {
  constructor() {
    this.valuesByKey = new Map;
  }
  get keys() {
    return Array.from(this.valuesByKey.keys());
  }
  get values() {
    const sets = Array.from(this.valuesByKey.values());
    return sets.reduce((values, set) => values.concat(Array.from(set)), []);
  }
  get size() {
    const sets = Array.from(this.valuesByKey.values());
    return sets.reduce((size, set) => size + set.size, 0);
  }
  add(key, value) {
    add(this.valuesByKey, key, value);
  }
  delete(key, value) {
    del(this.valuesByKey, key, value);
  }
  has(key, value) {
    const values = this.valuesByKey.get(key);
    return values != null && values.has(value);
  }
  hasKey(key) {
    return this.valuesByKey.has(key);
  }
  hasValue(value) {
    const sets = Array.from(this.valuesByKey.values());
    return sets.some((set) => set.has(value));
  }
  getValuesForKey(key) {
    const values = this.valuesByKey.get(key);
    return values ? Array.from(values) : [];
  }
  getKeysForValue(value) {
    return Array.from(this.valuesByKey).filter(([_key, values]) => values.has(value)).map(([key, _values]) => key);
  }
}
class SelectorObserver {
  constructor(element, selector, delegate, details) {
    this._selector = selector;
    this.details = details;
    this.elementObserver = new ElementObserver(element, this);
    this.delegate = delegate;
    this.matchesByElement = new Multimap;
  }
  get started() {
    return this.elementObserver.started;
  }
  get selector() {
    return this._selector;
  }
  set selector(selector) {
    this._selector = selector;
    this.refresh();
  }
  start() {
    this.elementObserver.start();
  }
  pause(callback) {
    this.elementObserver.pause(callback);
  }
  stop() {
    this.elementObserver.stop();
  }
  refresh() {
    this.elementObserver.refresh();
  }
  get element() {
    return this.elementObserver.element;
  }
  matchElement(element) {
    const { selector } = this;
    if (selector) {
      const matches = element.matches(selector);
      if (this.delegate.selectorMatchElement) {
        return matches && this.delegate.selectorMatchElement(element, this.details);
      }
      return matches;
    } else {
      return false;
    }
  }
  matchElementsInTree(tree) {
    const { selector } = this;
    if (selector) {
      const match = this.matchElement(tree) ? [tree] : [];
      const matches = Array.from(tree.querySelectorAll(selector)).filter((match2) => this.matchElement(match2));
      return match.concat(matches);
    } else {
      return [];
    }
  }
  elementMatched(element) {
    const { selector } = this;
    if (selector) {
      this.selectorMatched(element, selector);
    }
  }
  elementUnmatched(element) {
    const selectors = this.matchesByElement.getKeysForValue(element);
    for (const selector of selectors) {
      this.selectorUnmatched(element, selector);
    }
  }
  elementAttributeChanged(element, _attributeName) {
    const { selector } = this;
    if (selector) {
      const matches = this.matchElement(element);
      const matchedBefore = this.matchesByElement.has(selector, element);
      if (matches && !matchedBefore) {
        this.selectorMatched(element, selector);
      } else if (!matches && matchedBefore) {
        this.selectorUnmatched(element, selector);
      }
    }
  }
  selectorMatched(element, selector) {
    this.delegate.selectorMatched(element, selector, this.details);
    this.matchesByElement.add(selector, element);
  }
  selectorUnmatched(element, selector) {
    this.delegate.selectorUnmatched(element, selector, this.details);
    this.matchesByElement.delete(selector, element);
  }
}

class StringMapObserver {
  constructor(element, delegate) {
    this.element = element;
    this.delegate = delegate;
    this.started = false;
    this.stringMap = new Map;
    this.mutationObserver = new MutationObserver((mutations) => this.processMutations(mutations));
  }
  start() {
    if (!this.started) {
      this.started = true;
      this.mutationObserver.observe(this.element, { attributes: true, attributeOldValue: true });
      this.refresh();
    }
  }
  stop() {
    if (this.started) {
      this.mutationObserver.takeRecords();
      this.mutationObserver.disconnect();
      this.started = false;
    }
  }
  refresh() {
    if (this.started) {
      for (const attributeName of this.knownAttributeNames) {
        this.refreshAttribute(attributeName, null);
      }
    }
  }
  processMutations(mutations) {
    if (this.started) {
      for (const mutation of mutations) {
        this.processMutation(mutation);
      }
    }
  }
  processMutation(mutation) {
    const attributeName = mutation.attributeName;
    if (attributeName) {
      this.refreshAttribute(attributeName, mutation.oldValue);
    }
  }
  refreshAttribute(attributeName, oldValue) {
    const key = this.delegate.getStringMapKeyForAttribute(attributeName);
    if (key != null) {
      if (!this.stringMap.has(attributeName)) {
        this.stringMapKeyAdded(key, attributeName);
      }
      const value = this.element.getAttribute(attributeName);
      if (this.stringMap.get(attributeName) != value) {
        this.stringMapValueChanged(value, key, oldValue);
      }
      if (value == null) {
        const oldValue2 = this.stringMap.get(attributeName);
        this.stringMap.delete(attributeName);
        if (oldValue2)
          this.stringMapKeyRemoved(key, attributeName, oldValue2);
      } else {
        this.stringMap.set(attributeName, value);
      }
    }
  }
  stringMapKeyAdded(key, attributeName) {
    if (this.delegate.stringMapKeyAdded) {
      this.delegate.stringMapKeyAdded(key, attributeName);
    }
  }
  stringMapValueChanged(value, key, oldValue) {
    if (this.delegate.stringMapValueChanged) {
      this.delegate.stringMapValueChanged(value, key, oldValue);
    }
  }
  stringMapKeyRemoved(key, attributeName, oldValue) {
    if (this.delegate.stringMapKeyRemoved) {
      this.delegate.stringMapKeyRemoved(key, attributeName, oldValue);
    }
  }
  get knownAttributeNames() {
    return Array.from(new Set(this.currentAttributeNames.concat(this.recordedAttributeNames)));
  }
  get currentAttributeNames() {
    return Array.from(this.element.attributes).map((attribute) => attribute.name);
  }
  get recordedAttributeNames() {
    return Array.from(this.stringMap.keys());
  }
}

class TokenListObserver {
  constructor(element, attributeName, delegate) {
    this.attributeObserver = new AttributeObserver(element, attributeName, this);
    this.delegate = delegate;
    this.tokensByElement = new Multimap;
  }
  get started() {
    return this.attributeObserver.started;
  }
  start() {
    this.attributeObserver.start();
  }
  pause(callback) {
    this.attributeObserver.pause(callback);
  }
  stop() {
    this.attributeObserver.stop();
  }
  refresh() {
    this.attributeObserver.refresh();
  }
  get element() {
    return this.attributeObserver.element;
  }
  get attributeName() {
    return this.attributeObserver.attributeName;
  }
  elementMatchedAttribute(element) {
    this.tokensMatched(this.readTokensForElement(element));
  }
  elementAttributeValueChanged(element) {
    const [unmatchedTokens, matchedTokens] = this.refreshTokensForElement(element);
    this.tokensUnmatched(unmatchedTokens);
    this.tokensMatched(matchedTokens);
  }
  elementUnmatchedAttribute(element) {
    this.tokensUnmatched(this.tokensByElement.getValuesForKey(element));
  }
  tokensMatched(tokens) {
    tokens.forEach((token) => this.tokenMatched(token));
  }
  tokensUnmatched(tokens) {
    tokens.forEach((token) => this.tokenUnmatched(token));
  }
  tokenMatched(token) {
    this.delegate.tokenMatched(token);
    this.tokensByElement.add(token.element, token);
  }
  tokenUnmatched(token) {
    this.delegate.tokenUnmatched(token);
    this.tokensByElement.delete(token.element, token);
  }
  refreshTokensForElement(element) {
    const previousTokens = this.tokensByElement.getValuesForKey(element);
    const currentTokens = this.readTokensForElement(element);
    const firstDifferingIndex = zip(previousTokens, currentTokens).findIndex(([previousToken, currentToken]) => !tokensAreEqual(previousToken, currentToken));
    if (firstDifferingIndex == -1) {
      return [[], []];
    } else {
      return [previousTokens.slice(firstDifferingIndex), currentTokens.slice(firstDifferingIndex)];
    }
  }
  readTokensForElement(element) {
    const attributeName = this.attributeName;
    const tokenString = element.getAttribute(attributeName) || "";
    return parseTokenString(tokenString, element, attributeName);
  }
}
function parseTokenString(tokenString, element, attributeName) {
  return tokenString.trim().split(/\s+/).filter((content) => content.length).map((content, index) => ({ element, attributeName, content, index }));
}
function zip(left, right) {
  const length = Math.max(left.length, right.length);
  return Array.from({ length }, (_, index) => [left[index], right[index]]);
}
function tokensAreEqual(left, right) {
  return left && right && left.index == right.index && left.content == right.content;
}

class ValueListObserver {
  constructor(element, attributeName, delegate) {
    this.tokenListObserver = new TokenListObserver(element, attributeName, this);
    this.delegate = delegate;
    this.parseResultsByToken = new WeakMap;
    this.valuesByTokenByElement = new WeakMap;
  }
  get started() {
    return this.tokenListObserver.started;
  }
  start() {
    this.tokenListObserver.start();
  }
  stop() {
    this.tokenListObserver.stop();
  }
  refresh() {
    this.tokenListObserver.refresh();
  }
  get element() {
    return this.tokenListObserver.element;
  }
  get attributeName() {
    return this.tokenListObserver.attributeName;
  }
  tokenMatched(token) {
    const { element } = token;
    const { value } = this.fetchParseResultForToken(token);
    if (value) {
      this.fetchValuesByTokenForElement(element).set(token, value);
      this.delegate.elementMatchedValue(element, value);
    }
  }
  tokenUnmatched(token) {
    const { element } = token;
    const { value } = this.fetchParseResultForToken(token);
    if (value) {
      this.fetchValuesByTokenForElement(element).delete(token);
      this.delegate.elementUnmatchedValue(element, value);
    }
  }
  fetchParseResultForToken(token) {
    let parseResult = this.parseResultsByToken.get(token);
    if (!parseResult) {
      parseResult = this.parseToken(token);
      this.parseResultsByToken.set(token, parseResult);
    }
    return parseResult;
  }
  fetchValuesByTokenForElement(element) {
    let valuesByToken = this.valuesByTokenByElement.get(element);
    if (!valuesByToken) {
      valuesByToken = new Map;
      this.valuesByTokenByElement.set(element, valuesByToken);
    }
    return valuesByToken;
  }
  parseToken(token) {
    try {
      const value = this.delegate.parseValueForToken(token);
      return { value };
    } catch (error2) {
      return { error: error2 };
    }
  }
}

class BindingObserver {
  constructor(context, delegate) {
    this.context = context;
    this.delegate = delegate;
    this.bindingsByAction = new Map;
  }
  start() {
    if (!this.valueListObserver) {
      this.valueListObserver = new ValueListObserver(this.element, this.actionAttribute, this);
      this.valueListObserver.start();
    }
  }
  stop() {
    if (this.valueListObserver) {
      this.valueListObserver.stop();
      delete this.valueListObserver;
      this.disconnectAllActions();
    }
  }
  get element() {
    return this.context.element;
  }
  get identifier() {
    return this.context.identifier;
  }
  get actionAttribute() {
    return this.schema.actionAttribute;
  }
  get schema() {
    return this.context.schema;
  }
  get bindings() {
    return Array.from(this.bindingsByAction.values());
  }
  connectAction(action) {
    const binding = new Binding(this.context, action);
    this.bindingsByAction.set(action, binding);
    this.delegate.bindingConnected(binding);
  }
  disconnectAction(action) {
    const binding = this.bindingsByAction.get(action);
    if (binding) {
      this.bindingsByAction.delete(action);
      this.delegate.bindingDisconnected(binding);
    }
  }
  disconnectAllActions() {
    this.bindings.forEach((binding) => this.delegate.bindingDisconnected(binding, true));
    this.bindingsByAction.clear();
  }
  parseValueForToken(token) {
    const action = Action.forToken(token, this.schema);
    if (action.identifier == this.identifier) {
      return action;
    }
  }
  elementMatchedValue(element, action) {
    this.connectAction(action);
  }
  elementUnmatchedValue(element, action) {
    this.disconnectAction(action);
  }
}

class ValueObserver {
  constructor(context, receiver) {
    this.context = context;
    this.receiver = receiver;
    this.stringMapObserver = new StringMapObserver(this.element, this);
    this.valueDescriptorMap = this.controller.valueDescriptorMap;
  }
  start() {
    this.stringMapObserver.start();
    this.invokeChangedCallbacksForDefaultValues();
  }
  stop() {
    this.stringMapObserver.stop();
  }
  get element() {
    return this.context.element;
  }
  get controller() {
    return this.context.controller;
  }
  getStringMapKeyForAttribute(attributeName) {
    if (attributeName in this.valueDescriptorMap) {
      return this.valueDescriptorMap[attributeName].name;
    }
  }
  stringMapKeyAdded(key, attributeName) {
    const descriptor = this.valueDescriptorMap[attributeName];
    if (!this.hasValue(key)) {
      this.invokeChangedCallback(key, descriptor.writer(this.receiver[key]), descriptor.writer(descriptor.defaultValue));
    }
  }
  stringMapValueChanged(value, name, oldValue) {
    const descriptor = this.valueDescriptorNameMap[name];
    if (value === null)
      return;
    if (oldValue === null) {
      oldValue = descriptor.writer(descriptor.defaultValue);
    }
    this.invokeChangedCallback(name, value, oldValue);
  }
  stringMapKeyRemoved(key, attributeName, oldValue) {
    const descriptor = this.valueDescriptorNameMap[key];
    if (this.hasValue(key)) {
      this.invokeChangedCallback(key, descriptor.writer(this.receiver[key]), oldValue);
    } else {
      this.invokeChangedCallback(key, descriptor.writer(descriptor.defaultValue), oldValue);
    }
  }
  invokeChangedCallbacksForDefaultValues() {
    for (const { key, name, defaultValue, writer } of this.valueDescriptors) {
      if (defaultValue != null && !this.controller.data.has(key)) {
        this.invokeChangedCallback(name, writer(defaultValue), undefined);
      }
    }
  }
  invokeChangedCallback(name, rawValue, rawOldValue) {
    const changedMethodName = `${name}Changed`;
    const changedMethod = this.receiver[changedMethodName];
    if (typeof changedMethod == "function") {
      const descriptor = this.valueDescriptorNameMap[name];
      try {
        const value = descriptor.reader(rawValue);
        let oldValue = rawOldValue;
        if (rawOldValue) {
          oldValue = descriptor.reader(rawOldValue);
        }
        changedMethod.call(this.receiver, value, oldValue);
      } catch (error2) {
        if (error2 instanceof TypeError) {
          error2.message = `Stimulus Value "${this.context.identifier}.${descriptor.name}" - ${error2.message}`;
        }
        throw error2;
      }
    }
  }
  get valueDescriptors() {
    const { valueDescriptorMap } = this;
    return Object.keys(valueDescriptorMap).map((key) => valueDescriptorMap[key]);
  }
  get valueDescriptorNameMap() {
    const descriptors = {};
    Object.keys(this.valueDescriptorMap).forEach((key) => {
      const descriptor = this.valueDescriptorMap[key];
      descriptors[descriptor.name] = descriptor;
    });
    return descriptors;
  }
  hasValue(attributeName) {
    const descriptor = this.valueDescriptorNameMap[attributeName];
    const hasMethodName = `has${capitalize(descriptor.name)}`;
    return this.receiver[hasMethodName];
  }
}

class TargetObserver {
  constructor(context, delegate) {
    this.context = context;
    this.delegate = delegate;
    this.targetsByName = new Multimap;
  }
  start() {
    if (!this.tokenListObserver) {
      this.tokenListObserver = new TokenListObserver(this.element, this.attributeName, this);
      this.tokenListObserver.start();
    }
  }
  stop() {
    if (this.tokenListObserver) {
      this.disconnectAllTargets();
      this.tokenListObserver.stop();
      delete this.tokenListObserver;
    }
  }
  tokenMatched({ element, content: name }) {
    if (this.scope.containsElement(element)) {
      this.connectTarget(element, name);
    }
  }
  tokenUnmatched({ element, content: name }) {
    this.disconnectTarget(element, name);
  }
  connectTarget(element, name) {
    var _a;
    if (!this.targetsByName.has(name, element)) {
      this.targetsByName.add(name, element);
      (_a = this.tokenListObserver) === null || _a === undefined || _a.pause(() => this.delegate.targetConnected(element, name));
    }
  }
  disconnectTarget(element, name) {
    var _a;
    if (this.targetsByName.has(name, element)) {
      this.targetsByName.delete(name, element);
      (_a = this.tokenListObserver) === null || _a === undefined || _a.pause(() => this.delegate.targetDisconnected(element, name));
    }
  }
  disconnectAllTargets() {
    for (const name of this.targetsByName.keys) {
      for (const element of this.targetsByName.getValuesForKey(name)) {
        this.disconnectTarget(element, name);
      }
    }
  }
  get attributeName() {
    return `data-${this.context.identifier}-target`;
  }
  get element() {
    return this.context.element;
  }
  get scope() {
    return this.context.scope;
  }
}
function readInheritableStaticArrayValues(constructor, propertyName) {
  const ancestors = getAncestorsForConstructor(constructor);
  return Array.from(ancestors.reduce((values, constructor2) => {
    getOwnStaticArrayValues(constructor2, propertyName).forEach((name) => values.add(name));
    return values;
  }, new Set));
}
function readInheritableStaticObjectPairs(constructor, propertyName) {
  const ancestors = getAncestorsForConstructor(constructor);
  return ancestors.reduce((pairs, constructor2) => {
    pairs.push(...getOwnStaticObjectPairs(constructor2, propertyName));
    return pairs;
  }, []);
}
function getAncestorsForConstructor(constructor) {
  const ancestors = [];
  while (constructor) {
    ancestors.push(constructor);
    constructor = Object.getPrototypeOf(constructor);
  }
  return ancestors.reverse();
}
function getOwnStaticArrayValues(constructor, propertyName) {
  const definition = constructor[propertyName];
  return Array.isArray(definition) ? definition : [];
}
function getOwnStaticObjectPairs(constructor, propertyName) {
  const definition = constructor[propertyName];
  return definition ? Object.keys(definition).map((key) => [key, definition[key]]) : [];
}

class OutletObserver {
  constructor(context, delegate) {
    this.started = false;
    this.context = context;
    this.delegate = delegate;
    this.outletsByName = new Multimap;
    this.outletElementsByName = new Multimap;
    this.selectorObserverMap = new Map;
    this.attributeObserverMap = new Map;
  }
  start() {
    if (!this.started) {
      this.outletDefinitions.forEach((outletName) => {
        this.setupSelectorObserverForOutlet(outletName);
        this.setupAttributeObserverForOutlet(outletName);
      });
      this.started = true;
      this.dependentContexts.forEach((context) => context.refresh());
    }
  }
  refresh() {
    this.selectorObserverMap.forEach((observer) => observer.refresh());
    this.attributeObserverMap.forEach((observer) => observer.refresh());
  }
  stop() {
    if (this.started) {
      this.started = false;
      this.disconnectAllOutlets();
      this.stopSelectorObservers();
      this.stopAttributeObservers();
    }
  }
  stopSelectorObservers() {
    if (this.selectorObserverMap.size > 0) {
      this.selectorObserverMap.forEach((observer) => observer.stop());
      this.selectorObserverMap.clear();
    }
  }
  stopAttributeObservers() {
    if (this.attributeObserverMap.size > 0) {
      this.attributeObserverMap.forEach((observer) => observer.stop());
      this.attributeObserverMap.clear();
    }
  }
  selectorMatched(element, _selector, { outletName }) {
    const outlet = this.getOutlet(element, outletName);
    if (outlet) {
      this.connectOutlet(outlet, element, outletName);
    }
  }
  selectorUnmatched(element, _selector, { outletName }) {
    const outlet = this.getOutletFromMap(element, outletName);
    if (outlet) {
      this.disconnectOutlet(outlet, element, outletName);
    }
  }
  selectorMatchElement(element, { outletName }) {
    const selector = this.selector(outletName);
    const hasOutlet = this.hasOutlet(element, outletName);
    const hasOutletController = element.matches(`[${this.schema.controllerAttribute}~=${outletName}]`);
    if (selector) {
      return hasOutlet && hasOutletController && element.matches(selector);
    } else {
      return false;
    }
  }
  elementMatchedAttribute(_element, attributeName) {
    const outletName = this.getOutletNameFromOutletAttributeName(attributeName);
    if (outletName) {
      this.updateSelectorObserverForOutlet(outletName);
    }
  }
  elementAttributeValueChanged(_element, attributeName) {
    const outletName = this.getOutletNameFromOutletAttributeName(attributeName);
    if (outletName) {
      this.updateSelectorObserverForOutlet(outletName);
    }
  }
  elementUnmatchedAttribute(_element, attributeName) {
    const outletName = this.getOutletNameFromOutletAttributeName(attributeName);
    if (outletName) {
      this.updateSelectorObserverForOutlet(outletName);
    }
  }
  connectOutlet(outlet, element, outletName) {
    var _a;
    if (!this.outletElementsByName.has(outletName, element)) {
      this.outletsByName.add(outletName, outlet);
      this.outletElementsByName.add(outletName, element);
      (_a = this.selectorObserverMap.get(outletName)) === null || _a === undefined || _a.pause(() => this.delegate.outletConnected(outlet, element, outletName));
    }
  }
  disconnectOutlet(outlet, element, outletName) {
    var _a;
    if (this.outletElementsByName.has(outletName, element)) {
      this.outletsByName.delete(outletName, outlet);
      this.outletElementsByName.delete(outletName, element);
      (_a = this.selectorObserverMap.get(outletName)) === null || _a === undefined || _a.pause(() => this.delegate.outletDisconnected(outlet, element, outletName));
    }
  }
  disconnectAllOutlets() {
    for (const outletName of this.outletElementsByName.keys) {
      for (const element of this.outletElementsByName.getValuesForKey(outletName)) {
        for (const outlet of this.outletsByName.getValuesForKey(outletName)) {
          this.disconnectOutlet(outlet, element, outletName);
        }
      }
    }
  }
  updateSelectorObserverForOutlet(outletName) {
    const observer = this.selectorObserverMap.get(outletName);
    if (observer) {
      observer.selector = this.selector(outletName);
    }
  }
  setupSelectorObserverForOutlet(outletName) {
    const selector = this.selector(outletName);
    const selectorObserver = new SelectorObserver(document.body, selector, this, { outletName });
    this.selectorObserverMap.set(outletName, selectorObserver);
    selectorObserver.start();
  }
  setupAttributeObserverForOutlet(outletName) {
    const attributeName = this.attributeNameForOutletName(outletName);
    const attributeObserver = new AttributeObserver(this.scope.element, attributeName, this);
    this.attributeObserverMap.set(outletName, attributeObserver);
    attributeObserver.start();
  }
  selector(outletName) {
    return this.scope.outlets.getSelectorForOutletName(outletName);
  }
  attributeNameForOutletName(outletName) {
    return this.scope.schema.outletAttributeForScope(this.identifier, outletName);
  }
  getOutletNameFromOutletAttributeName(attributeName) {
    return this.outletDefinitions.find((outletName) => this.attributeNameForOutletName(outletName) === attributeName);
  }
  get outletDependencies() {
    const dependencies = new Multimap;
    this.router.modules.forEach((module) => {
      const constructor = module.definition.controllerConstructor;
      const outlets = readInheritableStaticArrayValues(constructor, "outlets");
      outlets.forEach((outlet) => dependencies.add(outlet, module.identifier));
    });
    return dependencies;
  }
  get outletDefinitions() {
    return this.outletDependencies.getKeysForValue(this.identifier);
  }
  get dependentControllerIdentifiers() {
    return this.outletDependencies.getValuesForKey(this.identifier);
  }
  get dependentContexts() {
    const identifiers = this.dependentControllerIdentifiers;
    return this.router.contexts.filter((context) => identifiers.includes(context.identifier));
  }
  hasOutlet(element, outletName) {
    return !!this.getOutlet(element, outletName) || !!this.getOutletFromMap(element, outletName);
  }
  getOutlet(element, outletName) {
    return this.application.getControllerForElementAndIdentifier(element, outletName);
  }
  getOutletFromMap(element, outletName) {
    return this.outletsByName.getValuesForKey(outletName).find((outlet) => outlet.element === element);
  }
  get scope() {
    return this.context.scope;
  }
  get schema() {
    return this.context.schema;
  }
  get identifier() {
    return this.context.identifier;
  }
  get application() {
    return this.context.application;
  }
  get router() {
    return this.application.router;
  }
}

class Context {
  constructor(module, scope) {
    this.logDebugActivity = (functionName, detail = {}) => {
      const { identifier, controller, element } = this;
      detail = Object.assign({ identifier, controller, element }, detail);
      this.application.logDebugActivity(this.identifier, functionName, detail);
    };
    this.module = module;
    this.scope = scope;
    this.controller = new module.controllerConstructor(this);
    this.bindingObserver = new BindingObserver(this, this.dispatcher);
    this.valueObserver = new ValueObserver(this, this.controller);
    this.targetObserver = new TargetObserver(this, this);
    this.outletObserver = new OutletObserver(this, this);
    try {
      this.controller.initialize();
      this.logDebugActivity("initialize");
    } catch (error2) {
      this.handleError(error2, "initializing controller");
    }
  }
  connect() {
    this.bindingObserver.start();
    this.valueObserver.start();
    this.targetObserver.start();
    this.outletObserver.start();
    try {
      this.controller.connect();
      this.logDebugActivity("connect");
    } catch (error2) {
      this.handleError(error2, "connecting controller");
    }
  }
  refresh() {
    this.outletObserver.refresh();
  }
  disconnect() {
    try {
      this.controller.disconnect();
      this.logDebugActivity("disconnect");
    } catch (error2) {
      this.handleError(error2, "disconnecting controller");
    }
    this.outletObserver.stop();
    this.targetObserver.stop();
    this.valueObserver.stop();
    this.bindingObserver.stop();
  }
  get application() {
    return this.module.application;
  }
  get identifier() {
    return this.module.identifier;
  }
  get schema() {
    return this.application.schema;
  }
  get dispatcher() {
    return this.application.dispatcher;
  }
  get element() {
    return this.scope.element;
  }
  get parentElement() {
    return this.element.parentElement;
  }
  handleError(error2, message, detail = {}) {
    const { identifier, controller, element } = this;
    detail = Object.assign({ identifier, controller, element }, detail);
    this.application.handleError(error2, `Error ${message}`, detail);
  }
  targetConnected(element, name) {
    this.invokeControllerMethod(`${name}TargetConnected`, element);
  }
  targetDisconnected(element, name) {
    this.invokeControllerMethod(`${name}TargetDisconnected`, element);
  }
  outletConnected(outlet, element, name) {
    this.invokeControllerMethod(`${namespaceCamelize(name)}OutletConnected`, outlet, element);
  }
  outletDisconnected(outlet, element, name) {
    this.invokeControllerMethod(`${namespaceCamelize(name)}OutletDisconnected`, outlet, element);
  }
  invokeControllerMethod(methodName, ...args) {
    const controller = this.controller;
    if (typeof controller[methodName] == "function") {
      controller[methodName](...args);
    }
  }
}
function bless(constructor) {
  return shadow(constructor, getBlessedProperties(constructor));
}
function shadow(constructor, properties) {
  const shadowConstructor = extend2(constructor);
  const shadowProperties = getShadowProperties(constructor.prototype, properties);
  Object.defineProperties(shadowConstructor.prototype, shadowProperties);
  return shadowConstructor;
}
function getBlessedProperties(constructor) {
  const blessings = readInheritableStaticArrayValues(constructor, "blessings");
  return blessings.reduce((blessedProperties, blessing) => {
    const properties = blessing(constructor);
    for (const key in properties) {
      const descriptor = blessedProperties[key] || {};
      blessedProperties[key] = Object.assign(descriptor, properties[key]);
    }
    return blessedProperties;
  }, {});
}
function getShadowProperties(prototype, properties) {
  return getOwnKeys(properties).reduce((shadowProperties, key) => {
    const descriptor = getShadowedDescriptor(prototype, properties, key);
    if (descriptor) {
      Object.assign(shadowProperties, { [key]: descriptor });
    }
    return shadowProperties;
  }, {});
}
function getShadowedDescriptor(prototype, properties, key) {
  const shadowingDescriptor = Object.getOwnPropertyDescriptor(prototype, key);
  const shadowedByValue = shadowingDescriptor && "value" in shadowingDescriptor;
  if (!shadowedByValue) {
    const descriptor = Object.getOwnPropertyDescriptor(properties, key).value;
    if (shadowingDescriptor) {
      descriptor.get = shadowingDescriptor.get || descriptor.get;
      descriptor.set = shadowingDescriptor.set || descriptor.set;
    }
    return descriptor;
  }
}
var getOwnKeys = (() => {
  if (typeof Object.getOwnPropertySymbols == "function") {
    return (object) => [...Object.getOwnPropertyNames(object), ...Object.getOwnPropertySymbols(object)];
  } else {
    return Object.getOwnPropertyNames;
  }
})();
var extend2 = (() => {
  function extendWithReflect(constructor) {
    function extended() {
      return Reflect.construct(constructor, arguments, new.target);
    }
    extended.prototype = Object.create(constructor.prototype, {
      constructor: { value: extended }
    });
    Reflect.setPrototypeOf(extended, constructor);
    return extended;
  }
  function testReflectExtension() {
    const a = function() {
      this.a.call(this);
    };
    const b = extendWithReflect(a);
    b.prototype.a = function() {
    };
    return new b;
  }
  try {
    testReflectExtension();
    return extendWithReflect;
  } catch (error2) {
    return (constructor) => class extended extends constructor {
    };
  }
})();
function blessDefinition(definition) {
  return {
    identifier: definition.identifier,
    controllerConstructor: bless(definition.controllerConstructor)
  };
}

class Module {
  constructor(application, definition) {
    this.application = application;
    this.definition = blessDefinition(definition);
    this.contextsByScope = new WeakMap;
    this.connectedContexts = new Set;
  }
  get identifier() {
    return this.definition.identifier;
  }
  get controllerConstructor() {
    return this.definition.controllerConstructor;
  }
  get contexts() {
    return Array.from(this.connectedContexts);
  }
  connectContextForScope(scope) {
    const context = this.fetchContextForScope(scope);
    this.connectedContexts.add(context);
    context.connect();
  }
  disconnectContextForScope(scope) {
    const context = this.contextsByScope.get(scope);
    if (context) {
      this.connectedContexts.delete(context);
      context.disconnect();
    }
  }
  fetchContextForScope(scope) {
    let context = this.contextsByScope.get(scope);
    if (!context) {
      context = new Context(this, scope);
      this.contextsByScope.set(scope, context);
    }
    return context;
  }
}

class ClassMap {
  constructor(scope) {
    this.scope = scope;
  }
  has(name) {
    return this.data.has(this.getDataKey(name));
  }
  get(name) {
    return this.getAll(name)[0];
  }
  getAll(name) {
    const tokenString = this.data.get(this.getDataKey(name)) || "";
    return tokenize(tokenString);
  }
  getAttributeName(name) {
    return this.data.getAttributeNameForKey(this.getDataKey(name));
  }
  getDataKey(name) {
    return `${name}-class`;
  }
  get data() {
    return this.scope.data;
  }
}

class DataMap {
  constructor(scope) {
    this.scope = scope;
  }
  get element() {
    return this.scope.element;
  }
  get identifier() {
    return this.scope.identifier;
  }
  get(key) {
    const name = this.getAttributeNameForKey(key);
    return this.element.getAttribute(name);
  }
  set(key, value) {
    const name = this.getAttributeNameForKey(key);
    this.element.setAttribute(name, value);
    return this.get(key);
  }
  has(key) {
    const name = this.getAttributeNameForKey(key);
    return this.element.hasAttribute(name);
  }
  delete(key) {
    if (this.has(key)) {
      const name = this.getAttributeNameForKey(key);
      this.element.removeAttribute(name);
      return true;
    } else {
      return false;
    }
  }
  getAttributeNameForKey(key) {
    return `data-${this.identifier}-${dasherize(key)}`;
  }
}

class Guide {
  constructor(logger) {
    this.warnedKeysByObject = new WeakMap;
    this.logger = logger;
  }
  warn(object, key, message) {
    let warnedKeys = this.warnedKeysByObject.get(object);
    if (!warnedKeys) {
      warnedKeys = new Set;
      this.warnedKeysByObject.set(object, warnedKeys);
    }
    if (!warnedKeys.has(key)) {
      warnedKeys.add(key);
      this.logger.warn(message, object);
    }
  }
}
function attributeValueContainsToken(attributeName, token) {
  return `[${attributeName}~="${token}"]`;
}

class TargetSet {
  constructor(scope) {
    this.scope = scope;
  }
  get element() {
    return this.scope.element;
  }
  get identifier() {
    return this.scope.identifier;
  }
  get schema() {
    return this.scope.schema;
  }
  has(targetName) {
    return this.find(targetName) != null;
  }
  find(...targetNames) {
    return targetNames.reduce((target, targetName) => target || this.findTarget(targetName) || this.findLegacyTarget(targetName), undefined);
  }
  findAll(...targetNames) {
    return targetNames.reduce((targets, targetName) => [
      ...targets,
      ...this.findAllTargets(targetName),
      ...this.findAllLegacyTargets(targetName)
    ], []);
  }
  findTarget(targetName) {
    const selector = this.getSelectorForTargetName(targetName);
    return this.scope.findElement(selector);
  }
  findAllTargets(targetName) {
    const selector = this.getSelectorForTargetName(targetName);
    return this.scope.findAllElements(selector);
  }
  getSelectorForTargetName(targetName) {
    const attributeName = this.schema.targetAttributeForScope(this.identifier);
    return attributeValueContainsToken(attributeName, targetName);
  }
  findLegacyTarget(targetName) {
    const selector = this.getLegacySelectorForTargetName(targetName);
    return this.deprecate(this.scope.findElement(selector), targetName);
  }
  findAllLegacyTargets(targetName) {
    const selector = this.getLegacySelectorForTargetName(targetName);
    return this.scope.findAllElements(selector).map((element) => this.deprecate(element, targetName));
  }
  getLegacySelectorForTargetName(targetName) {
    const targetDescriptor = `${this.identifier}.${targetName}`;
    return attributeValueContainsToken(this.schema.targetAttribute, targetDescriptor);
  }
  deprecate(element, targetName) {
    if (element) {
      const { identifier } = this;
      const attributeName = this.schema.targetAttribute;
      const revisedAttributeName = this.schema.targetAttributeForScope(identifier);
      this.guide.warn(element, `target:${targetName}`, `Please replace ${attributeName}="${identifier}.${targetName}" with ${revisedAttributeName}="${targetName}". ` + `The ${attributeName} attribute is deprecated and will be removed in a future version of Stimulus.`);
    }
    return element;
  }
  get guide() {
    return this.scope.guide;
  }
}

class OutletSet {
  constructor(scope, controllerElement) {
    this.scope = scope;
    this.controllerElement = controllerElement;
  }
  get element() {
    return this.scope.element;
  }
  get identifier() {
    return this.scope.identifier;
  }
  get schema() {
    return this.scope.schema;
  }
  has(outletName) {
    return this.find(outletName) != null;
  }
  find(...outletNames) {
    return outletNames.reduce((outlet, outletName) => outlet || this.findOutlet(outletName), undefined);
  }
  findAll(...outletNames) {
    return outletNames.reduce((outlets, outletName) => [...outlets, ...this.findAllOutlets(outletName)], []);
  }
  getSelectorForOutletName(outletName) {
    const attributeName = this.schema.outletAttributeForScope(this.identifier, outletName);
    return this.controllerElement.getAttribute(attributeName);
  }
  findOutlet(outletName) {
    const selector = this.getSelectorForOutletName(outletName);
    if (selector)
      return this.findElement(selector, outletName);
  }
  findAllOutlets(outletName) {
    const selector = this.getSelectorForOutletName(outletName);
    return selector ? this.findAllElements(selector, outletName) : [];
  }
  findElement(selector, outletName) {
    const elements = this.scope.queryElements(selector);
    return elements.filter((element) => this.matchesElement(element, selector, outletName))[0];
  }
  findAllElements(selector, outletName) {
    const elements = this.scope.queryElements(selector);
    return elements.filter((element) => this.matchesElement(element, selector, outletName));
  }
  matchesElement(element, selector, outletName) {
    const controllerAttribute = element.getAttribute(this.scope.schema.controllerAttribute) || "";
    return element.matches(selector) && controllerAttribute.split(" ").includes(outletName);
  }
}

class Scope {
  constructor(schema, element, identifier, logger) {
    this.targets = new TargetSet(this);
    this.classes = new ClassMap(this);
    this.data = new DataMap(this);
    this.containsElement = (element2) => {
      return element2.closest(this.controllerSelector) === this.element;
    };
    this.schema = schema;
    this.element = element;
    this.identifier = identifier;
    this.guide = new Guide(logger);
    this.outlets = new OutletSet(this.documentScope, element);
  }
  findElement(selector) {
    return this.element.matches(selector) ? this.element : this.queryElements(selector).find(this.containsElement);
  }
  findAllElements(selector) {
    return [
      ...this.element.matches(selector) ? [this.element] : [],
      ...this.queryElements(selector).filter(this.containsElement)
    ];
  }
  queryElements(selector) {
    return Array.from(this.element.querySelectorAll(selector));
  }
  get controllerSelector() {
    return attributeValueContainsToken(this.schema.controllerAttribute, this.identifier);
  }
  get isDocumentScope() {
    return this.element === document.documentElement;
  }
  get documentScope() {
    return this.isDocumentScope ? this : new Scope(this.schema, document.documentElement, this.identifier, this.guide.logger);
  }
}

class ScopeObserver {
  constructor(element, schema, delegate) {
    this.element = element;
    this.schema = schema;
    this.delegate = delegate;
    this.valueListObserver = new ValueListObserver(this.element, this.controllerAttribute, this);
    this.scopesByIdentifierByElement = new WeakMap;
    this.scopeReferenceCounts = new WeakMap;
  }
  start() {
    this.valueListObserver.start();
  }
  stop() {
    this.valueListObserver.stop();
  }
  get controllerAttribute() {
    return this.schema.controllerAttribute;
  }
  parseValueForToken(token) {
    const { element, content: identifier } = token;
    return this.parseValueForElementAndIdentifier(element, identifier);
  }
  parseValueForElementAndIdentifier(element, identifier) {
    const scopesByIdentifier = this.fetchScopesByIdentifierForElement(element);
    let scope = scopesByIdentifier.get(identifier);
    if (!scope) {
      scope = this.delegate.createScopeForElementAndIdentifier(element, identifier);
      scopesByIdentifier.set(identifier, scope);
    }
    return scope;
  }
  elementMatchedValue(element, value) {
    const referenceCount = (this.scopeReferenceCounts.get(value) || 0) + 1;
    this.scopeReferenceCounts.set(value, referenceCount);
    if (referenceCount == 1) {
      this.delegate.scopeConnected(value);
    }
  }
  elementUnmatchedValue(element, value) {
    const referenceCount = this.scopeReferenceCounts.get(value);
    if (referenceCount) {
      this.scopeReferenceCounts.set(value, referenceCount - 1);
      if (referenceCount == 1) {
        this.delegate.scopeDisconnected(value);
      }
    }
  }
  fetchScopesByIdentifierForElement(element) {
    let scopesByIdentifier = this.scopesByIdentifierByElement.get(element);
    if (!scopesByIdentifier) {
      scopesByIdentifier = new Map;
      this.scopesByIdentifierByElement.set(element, scopesByIdentifier);
    }
    return scopesByIdentifier;
  }
}

class Router {
  constructor(application) {
    this.application = application;
    this.scopeObserver = new ScopeObserver(this.element, this.schema, this);
    this.scopesByIdentifier = new Multimap;
    this.modulesByIdentifier = new Map;
  }
  get element() {
    return this.application.element;
  }
  get schema() {
    return this.application.schema;
  }
  get logger() {
    return this.application.logger;
  }
  get controllerAttribute() {
    return this.schema.controllerAttribute;
  }
  get modules() {
    return Array.from(this.modulesByIdentifier.values());
  }
  get contexts() {
    return this.modules.reduce((contexts, module) => contexts.concat(module.contexts), []);
  }
  start() {
    this.scopeObserver.start();
  }
  stop() {
    this.scopeObserver.stop();
  }
  loadDefinition(definition) {
    this.unloadIdentifier(definition.identifier);
    const module = new Module(this.application, definition);
    this.connectModule(module);
    const afterLoad = definition.controllerConstructor.afterLoad;
    if (afterLoad) {
      afterLoad.call(definition.controllerConstructor, definition.identifier, this.application);
    }
  }
  unloadIdentifier(identifier) {
    const module = this.modulesByIdentifier.get(identifier);
    if (module) {
      this.disconnectModule(module);
    }
  }
  getContextForElementAndIdentifier(element, identifier) {
    const module = this.modulesByIdentifier.get(identifier);
    if (module) {
      return module.contexts.find((context) => context.element == element);
    }
  }
  proposeToConnectScopeForElementAndIdentifier(element, identifier) {
    const scope = this.scopeObserver.parseValueForElementAndIdentifier(element, identifier);
    if (scope) {
      this.scopeObserver.elementMatchedValue(scope.element, scope);
    } else {
      console.error(`Couldn't find or create scope for identifier: "${identifier}" and element:`, element);
    }
  }
  handleError(error2, message, detail) {
    this.application.handleError(error2, message, detail);
  }
  createScopeForElementAndIdentifier(element, identifier) {
    return new Scope(this.schema, element, identifier, this.logger);
  }
  scopeConnected(scope) {
    this.scopesByIdentifier.add(scope.identifier, scope);
    const module = this.modulesByIdentifier.get(scope.identifier);
    if (module) {
      module.connectContextForScope(scope);
    }
  }
  scopeDisconnected(scope) {
    this.scopesByIdentifier.delete(scope.identifier, scope);
    const module = this.modulesByIdentifier.get(scope.identifier);
    if (module) {
      module.disconnectContextForScope(scope);
    }
  }
  connectModule(module) {
    this.modulesByIdentifier.set(module.identifier, module);
    const scopes = this.scopesByIdentifier.getValuesForKey(module.identifier);
    scopes.forEach((scope) => module.connectContextForScope(scope));
  }
  disconnectModule(module) {
    this.modulesByIdentifier.delete(module.identifier);
    const scopes = this.scopesByIdentifier.getValuesForKey(module.identifier);
    scopes.forEach((scope) => module.disconnectContextForScope(scope));
  }
}
var defaultSchema = {
  controllerAttribute: "data-controller",
  actionAttribute: "data-action",
  targetAttribute: "data-target",
  targetAttributeForScope: (identifier) => `data-${identifier}-target`,
  outletAttributeForScope: (identifier, outlet) => `data-${identifier}-${outlet}-outlet`,
  keyMappings: Object.assign(Object.assign({ enter: "Enter", tab: "Tab", esc: "Escape", space: " ", up: "ArrowUp", down: "ArrowDown", left: "ArrowLeft", right: "ArrowRight", home: "Home", end: "End", page_up: "PageUp", page_down: "PageDown" }, objectFromEntries("abcdefghijklmnopqrstuvwxyz".split("").map((c) => [c, c]))), objectFromEntries("0123456789".split("").map((n) => [n, n])))
};
function objectFromEntries(array) {
  return array.reduce((memo, [k, v]) => Object.assign(Object.assign({}, memo), { [k]: v }), {});
}

class Application {
  constructor(element = document.documentElement, schema = defaultSchema) {
    this.logger = console;
    this.debug = false;
    this.logDebugActivity = (identifier, functionName, detail = {}) => {
      if (this.debug) {
        this.logFormattedMessage(identifier, functionName, detail);
      }
    };
    this.element = element;
    this.schema = schema;
    this.dispatcher = new Dispatcher(this);
    this.router = new Router(this);
    this.actionDescriptorFilters = Object.assign({}, defaultActionDescriptorFilters);
  }
  static start(element, schema) {
    const application = new this(element, schema);
    application.start();
    return application;
  }
  async start() {
    await domReady();
    this.logDebugActivity("application", "starting");
    this.dispatcher.start();
    this.router.start();
    this.logDebugActivity("application", "start");
  }
  stop() {
    this.logDebugActivity("application", "stopping");
    this.dispatcher.stop();
    this.router.stop();
    this.logDebugActivity("application", "stop");
  }
  register(identifier, controllerConstructor) {
    this.load({ identifier, controllerConstructor });
  }
  registerActionOption(name, filter) {
    this.actionDescriptorFilters[name] = filter;
  }
  load(head, ...rest) {
    const definitions = Array.isArray(head) ? head : [head, ...rest];
    definitions.forEach((definition) => {
      if (definition.controllerConstructor.shouldLoad) {
        this.router.loadDefinition(definition);
      }
    });
  }
  unload(head, ...rest) {
    const identifiers = Array.isArray(head) ? head : [head, ...rest];
    identifiers.forEach((identifier) => this.router.unloadIdentifier(identifier));
  }
  get controllers() {
    return this.router.contexts.map((context) => context.controller);
  }
  getControllerForElementAndIdentifier(element, identifier) {
    const context = this.router.getContextForElementAndIdentifier(element, identifier);
    return context ? context.controller : null;
  }
  handleError(error2, message, detail) {
    var _a;
    this.logger.error(`%s

%o

%o`, message, error2, detail);
    (_a = window.onerror) === null || _a === undefined || _a.call(window, message, "", 0, 0, error2);
  }
  logFormattedMessage(identifier, functionName, detail = {}) {
    detail = Object.assign({ application: this }, detail);
    this.logger.groupCollapsed(`${identifier} #${functionName}`);
    this.logger.log("details:", Object.assign({}, detail));
    this.logger.groupEnd();
  }
}
function domReady() {
  return new Promise((resolve) => {
    if (document.readyState == "loading") {
      document.addEventListener("DOMContentLoaded", () => resolve());
    } else {
      resolve();
    }
  });
}
function ClassPropertiesBlessing(constructor) {
  const classes = readInheritableStaticArrayValues(constructor, "classes");
  return classes.reduce((properties, classDefinition) => {
    return Object.assign(properties, propertiesForClassDefinition(classDefinition));
  }, {});
}
function propertiesForClassDefinition(key) {
  return {
    [`${key}Class`]: {
      get() {
        const { classes } = this;
        if (classes.has(key)) {
          return classes.get(key);
        } else {
          const attribute = classes.getAttributeName(key);
          throw new Error(`Missing attribute "${attribute}"`);
        }
      }
    },
    [`${key}Classes`]: {
      get() {
        return this.classes.getAll(key);
      }
    },
    [`has${capitalize(key)}Class`]: {
      get() {
        return this.classes.has(key);
      }
    }
  };
}
function OutletPropertiesBlessing(constructor) {
  const outlets = readInheritableStaticArrayValues(constructor, "outlets");
  return outlets.reduce((properties, outletDefinition) => {
    return Object.assign(properties, propertiesForOutletDefinition(outletDefinition));
  }, {});
}
function getOutletController(controller, element, identifier) {
  return controller.application.getControllerForElementAndIdentifier(element, identifier);
}
function getControllerAndEnsureConnectedScope(controller, element, outletName) {
  let outletController = getOutletController(controller, element, outletName);
  if (outletController)
    return outletController;
  controller.application.router.proposeToConnectScopeForElementAndIdentifier(element, outletName);
  outletController = getOutletController(controller, element, outletName);
  if (outletController)
    return outletController;
}
function propertiesForOutletDefinition(name) {
  const camelizedName = namespaceCamelize(name);
  return {
    [`${camelizedName}Outlet`]: {
      get() {
        const outletElement = this.outlets.find(name);
        const selector = this.outlets.getSelectorForOutletName(name);
        if (outletElement) {
          const outletController = getControllerAndEnsureConnectedScope(this, outletElement, name);
          if (outletController)
            return outletController;
          throw new Error(`The provided outlet element is missing an outlet controller "${name}" instance for host controller "${this.identifier}"`);
        }
        throw new Error(`Missing outlet element "${name}" for host controller "${this.identifier}". Stimulus couldn't find a matching outlet element using selector "${selector}".`);
      }
    },
    [`${camelizedName}Outlets`]: {
      get() {
        const outlets = this.outlets.findAll(name);
        if (outlets.length > 0) {
          return outlets.map((outletElement) => {
            const outletController = getControllerAndEnsureConnectedScope(this, outletElement, name);
            if (outletController)
              return outletController;
            console.warn(`The provided outlet element is missing an outlet controller "${name}" instance for host controller "${this.identifier}"`, outletElement);
          }).filter((controller) => controller);
        }
        return [];
      }
    },
    [`${camelizedName}OutletElement`]: {
      get() {
        const outletElement = this.outlets.find(name);
        const selector = this.outlets.getSelectorForOutletName(name);
        if (outletElement) {
          return outletElement;
        } else {
          throw new Error(`Missing outlet element "${name}" for host controller "${this.identifier}". Stimulus couldn't find a matching outlet element using selector "${selector}".`);
        }
      }
    },
    [`${camelizedName}OutletElements`]: {
      get() {
        return this.outlets.findAll(name);
      }
    },
    [`has${capitalize(camelizedName)}Outlet`]: {
      get() {
        return this.outlets.has(name);
      }
    }
  };
}
function TargetPropertiesBlessing(constructor) {
  const targets = readInheritableStaticArrayValues(constructor, "targets");
  return targets.reduce((properties, targetDefinition) => {
    return Object.assign(properties, propertiesForTargetDefinition(targetDefinition));
  }, {});
}
function propertiesForTargetDefinition(name) {
  return {
    [`${name}Target`]: {
      get() {
        const target = this.targets.find(name);
        if (target) {
          return target;
        } else {
          throw new Error(`Missing target element "${name}" for "${this.identifier}" controller`);
        }
      }
    },
    [`${name}Targets`]: {
      get() {
        return this.targets.findAll(name);
      }
    },
    [`has${capitalize(name)}Target`]: {
      get() {
        return this.targets.has(name);
      }
    }
  };
}
function ValuePropertiesBlessing(constructor) {
  const valueDefinitionPairs = readInheritableStaticObjectPairs(constructor, "values");
  const propertyDescriptorMap = {
    valueDescriptorMap: {
      get() {
        return valueDefinitionPairs.reduce((result, valueDefinitionPair) => {
          const valueDescriptor = parseValueDefinitionPair(valueDefinitionPair, this.identifier);
          const attributeName = this.data.getAttributeNameForKey(valueDescriptor.key);
          return Object.assign(result, { [attributeName]: valueDescriptor });
        }, {});
      }
    }
  };
  return valueDefinitionPairs.reduce((properties, valueDefinitionPair) => {
    return Object.assign(properties, propertiesForValueDefinitionPair(valueDefinitionPair));
  }, propertyDescriptorMap);
}
function propertiesForValueDefinitionPair(valueDefinitionPair, controller) {
  const definition = parseValueDefinitionPair(valueDefinitionPair, controller);
  const { key, name, reader: read, writer: write } = definition;
  return {
    [name]: {
      get() {
        const value = this.data.get(key);
        if (value !== null) {
          return read(value);
        } else {
          return definition.defaultValue;
        }
      },
      set(value) {
        if (value === undefined) {
          this.data.delete(key);
        } else {
          this.data.set(key, write(value));
        }
      }
    },
    [`has${capitalize(name)}`]: {
      get() {
        return this.data.has(key) || definition.hasCustomDefaultValue;
      }
    }
  };
}
function parseValueDefinitionPair([token, typeDefinition], controller) {
  return valueDescriptorForTokenAndTypeDefinition({
    controller,
    token,
    typeDefinition
  });
}
function parseValueTypeConstant(constant) {
  switch (constant) {
    case Array:
      return "array";
    case Boolean:
      return "boolean";
    case Number:
      return "number";
    case Object:
      return "object";
    case String:
      return "string";
  }
}
function parseValueTypeDefault(defaultValue) {
  switch (typeof defaultValue) {
    case "boolean":
      return "boolean";
    case "number":
      return "number";
    case "string":
      return "string";
  }
  if (Array.isArray(defaultValue))
    return "array";
  if (Object.prototype.toString.call(defaultValue) === "[object Object]")
    return "object";
}
function parseValueTypeObject(payload) {
  const { controller, token, typeObject } = payload;
  const hasType = isSomething(typeObject.type);
  const hasDefault = isSomething(typeObject.default);
  const fullObject = hasType && hasDefault;
  const onlyType = hasType && !hasDefault;
  const onlyDefault = !hasType && hasDefault;
  const typeFromObject = parseValueTypeConstant(typeObject.type);
  const typeFromDefaultValue = parseValueTypeDefault(payload.typeObject.default);
  if (onlyType)
    return typeFromObject;
  if (onlyDefault)
    return typeFromDefaultValue;
  if (typeFromObject !== typeFromDefaultValue) {
    const propertyPath = controller ? `${controller}.${token}` : token;
    throw new Error(`The specified default value for the Stimulus Value "${propertyPath}" must match the defined type "${typeFromObject}". The provided default value of "${typeObject.default}" is of type "${typeFromDefaultValue}".`);
  }
  if (fullObject)
    return typeFromObject;
}
function parseValueTypeDefinition(payload) {
  const { controller, token, typeDefinition } = payload;
  const typeObject = { controller, token, typeObject: typeDefinition };
  const typeFromObject = parseValueTypeObject(typeObject);
  const typeFromDefaultValue = parseValueTypeDefault(typeDefinition);
  const typeFromConstant = parseValueTypeConstant(typeDefinition);
  const type = typeFromObject || typeFromDefaultValue || typeFromConstant;
  if (type)
    return type;
  const propertyPath = controller ? `${controller}.${typeDefinition}` : token;
  throw new Error(`Unknown value type "${propertyPath}" for "${token}" value`);
}
function defaultValueForDefinition(typeDefinition) {
  const constant = parseValueTypeConstant(typeDefinition);
  if (constant)
    return defaultValuesByType[constant];
  const hasDefault = hasProperty(typeDefinition, "default");
  const hasType = hasProperty(typeDefinition, "type");
  const typeObject = typeDefinition;
  if (hasDefault)
    return typeObject.default;
  if (hasType) {
    const { type } = typeObject;
    const constantFromType = parseValueTypeConstant(type);
    if (constantFromType)
      return defaultValuesByType[constantFromType];
  }
  return typeDefinition;
}
function valueDescriptorForTokenAndTypeDefinition(payload) {
  const { token, typeDefinition } = payload;
  const key = `${dasherize(token)}-value`;
  const type = parseValueTypeDefinition(payload);
  return {
    type,
    key,
    name: camelize(key),
    get defaultValue() {
      return defaultValueForDefinition(typeDefinition);
    },
    get hasCustomDefaultValue() {
      return parseValueTypeDefault(typeDefinition) !== undefined;
    },
    reader: readers[type],
    writer: writers[type] || writers.default
  };
}
var defaultValuesByType = {
  get array() {
    return [];
  },
  boolean: false,
  number: 0,
  get object() {
    return {};
  },
  string: ""
};
var readers = {
  array(value) {
    const array = JSON.parse(value);
    if (!Array.isArray(array)) {
      throw new TypeError(`expected value of type "array" but instead got value "${value}" of type "${parseValueTypeDefault(array)}"`);
    }
    return array;
  },
  boolean(value) {
    return !(value == "0" || String(value).toLowerCase() == "false");
  },
  number(value) {
    return Number(value.replace(/_/g, ""));
  },
  object(value) {
    const object = JSON.parse(value);
    if (object === null || typeof object != "object" || Array.isArray(object)) {
      throw new TypeError(`expected value of type "object" but instead got value "${value}" of type "${parseValueTypeDefault(object)}"`);
    }
    return object;
  },
  string(value) {
    return value;
  }
};
var writers = {
  default: writeString,
  array: writeJSON,
  object: writeJSON
};
function writeJSON(value) {
  return JSON.stringify(value);
}
function writeString(value) {
  return `${value}`;
}

class Controller {
  constructor(context) {
    this.context = context;
  }
  static get shouldLoad() {
    return true;
  }
  static afterLoad(_identifier, _application) {
    return;
  }
  get application() {
    return this.context.application;
  }
  get scope() {
    return this.context.scope;
  }
  get element() {
    return this.scope.element;
  }
  get identifier() {
    return this.scope.identifier;
  }
  get targets() {
    return this.scope.targets;
  }
  get outlets() {
    return this.scope.outlets;
  }
  get classes() {
    return this.scope.classes;
  }
  get data() {
    return this.scope.data;
  }
  initialize() {
  }
  connect() {
  }
  disconnect() {
  }
  dispatch(eventName, { target = this.element, detail = {}, prefix = this.identifier, bubbles = true, cancelable = true } = {}) {
    const type = prefix ? `${prefix}:${eventName}` : eventName;
    const event = new CustomEvent(type, { detail, bubbles, cancelable });
    target.dispatchEvent(event);
    return event;
  }
}
Controller.blessings = [
  ClassPropertiesBlessing,
  TargetPropertiesBlessing,
  ValuePropertiesBlessing,
  OutletPropertiesBlessing
];
Controller.targets = [];
Controller.outlets = [];
Controller.values = {};

// node_modules/@rails/actioncable/app/assets/javascripts/actioncable.esm.js
var adapters = {
  logger: typeof console !== "undefined" ? console : undefined,
  WebSocket: typeof WebSocket !== "undefined" ? WebSocket : undefined
};
var logger = {
  log(...messages) {
    if (this.enabled) {
      messages.push(Date.now());
      adapters.logger.log("[ActionCable]", ...messages);
    }
  }
};
var now2 = () => new Date().getTime();
var secondsSince2 = (time) => (now2() - time) / 1000;

class ConnectionMonitor2 {
  constructor(connection) {
    this.visibilityDidChange = this.visibilityDidChange.bind(this);
    this.connection = connection;
    this.reconnectAttempts = 0;
  }
  start() {
    if (!this.isRunning()) {
      this.startedAt = now2();
      delete this.stoppedAt;
      this.startPolling();
      addEventListener("visibilitychange", this.visibilityDidChange);
      logger.log(`ConnectionMonitor started. stale threshold = ${this.constructor.staleThreshold} s`);
    }
  }
  stop() {
    if (this.isRunning()) {
      this.stoppedAt = now2();
      this.stopPolling();
      removeEventListener("visibilitychange", this.visibilityDidChange);
      logger.log("ConnectionMonitor stopped");
    }
  }
  isRunning() {
    return this.startedAt && !this.stoppedAt;
  }
  recordMessage() {
    this.pingedAt = now2();
  }
  recordConnect() {
    this.reconnectAttempts = 0;
    delete this.disconnectedAt;
    logger.log("ConnectionMonitor recorded connect");
  }
  recordDisconnect() {
    this.disconnectedAt = now2();
    logger.log("ConnectionMonitor recorded disconnect");
  }
  startPolling() {
    this.stopPolling();
    this.poll();
  }
  stopPolling() {
    clearTimeout(this.pollTimeout);
  }
  poll() {
    this.pollTimeout = setTimeout(() => {
      this.reconnectIfStale();
      this.poll();
    }, this.getPollInterval());
  }
  getPollInterval() {
    const { staleThreshold, reconnectionBackoffRate } = this.constructor;
    const backoff = Math.pow(1 + reconnectionBackoffRate, Math.min(this.reconnectAttempts, 10));
    const jitterMax = this.reconnectAttempts === 0 ? 1 : reconnectionBackoffRate;
    const jitter = jitterMax * Math.random();
    return staleThreshold * 1000 * backoff * (1 + jitter);
  }
  reconnectIfStale() {
    if (this.connectionIsStale()) {
      logger.log(`ConnectionMonitor detected stale connection. reconnectAttempts = ${this.reconnectAttempts}, time stale = ${secondsSince2(this.refreshedAt)} s, stale threshold = ${this.constructor.staleThreshold} s`);
      this.reconnectAttempts++;
      if (this.disconnectedRecently()) {
        logger.log(`ConnectionMonitor skipping reopening recent disconnect. time disconnected = ${secondsSince2(this.disconnectedAt)} s`);
      } else {
        logger.log("ConnectionMonitor reopening");
        this.connection.reopen();
      }
    }
  }
  get refreshedAt() {
    return this.pingedAt ? this.pingedAt : this.startedAt;
  }
  connectionIsStale() {
    return secondsSince2(this.refreshedAt) > this.constructor.staleThreshold;
  }
  disconnectedRecently() {
    return this.disconnectedAt && secondsSince2(this.disconnectedAt) < this.constructor.staleThreshold;
  }
  visibilityDidChange() {
    if (document.visibilityState === "visible") {
      setTimeout(() => {
        if (this.connectionIsStale() || !this.connection.isOpen()) {
          logger.log(`ConnectionMonitor reopening stale connection on visibilitychange. visibilityState = ${document.visibilityState}`);
          this.connection.reopen();
        }
      }, 200);
    }
  }
}
ConnectionMonitor2.staleThreshold = 6;
ConnectionMonitor2.reconnectionBackoffRate = 0.15;
var INTERNAL = {
  message_types: {
    welcome: "welcome",
    disconnect: "disconnect",
    ping: "ping",
    confirmation: "confirm_subscription",
    rejection: "reject_subscription"
  },
  disconnect_reasons: {
    unauthorized: "unauthorized",
    invalid_request: "invalid_request",
    server_restart: "server_restart",
    remote: "remote"
  },
  default_mount_path: "/cable",
  protocols: ["actioncable-v1-json", "actioncable-unsupported"]
};
var { message_types: message_types2, protocols: protocols2 } = INTERNAL;
var supportedProtocols2 = protocols2.slice(0, protocols2.length - 1);
var indexOf2 = [].indexOf;

class Connection2 {
  constructor(consumer2) {
    this.open = this.open.bind(this);
    this.consumer = consumer2;
    this.subscriptions = this.consumer.subscriptions;
    this.monitor = new ConnectionMonitor2(this);
    this.disconnected = true;
  }
  send(data) {
    if (this.isOpen()) {
      this.webSocket.send(JSON.stringify(data));
      return true;
    } else {
      return false;
    }
  }
  open() {
    if (this.isActive()) {
      logger.log(`Attempted to open WebSocket, but existing socket is ${this.getState()}`);
      return false;
    } else {
      const socketProtocols = [...protocols2, ...this.consumer.subprotocols || []];
      logger.log(`Opening WebSocket, current state is ${this.getState()}, subprotocols: ${socketProtocols}`);
      if (this.webSocket) {
        this.uninstallEventHandlers();
      }
      this.webSocket = new adapters.WebSocket(this.consumer.url, socketProtocols);
      this.installEventHandlers();
      this.monitor.start();
      return true;
    }
  }
  close({ allowReconnect } = {
    allowReconnect: true
  }) {
    if (!allowReconnect) {
      this.monitor.stop();
    }
    if (this.isOpen()) {
      return this.webSocket.close();
    }
  }
  reopen() {
    logger.log(`Reopening WebSocket, current state is ${this.getState()}`);
    if (this.isActive()) {
      try {
        return this.close();
      } catch (error2) {
        logger.log("Failed to reopen WebSocket", error2);
      } finally {
        logger.log(`Reopening WebSocket in ${this.constructor.reopenDelay}ms`);
        setTimeout(this.open, this.constructor.reopenDelay);
      }
    } else {
      return this.open();
    }
  }
  getProtocol() {
    if (this.webSocket) {
      return this.webSocket.protocol;
    }
  }
  isOpen() {
    return this.isState("open");
  }
  isActive() {
    return this.isState("open", "connecting");
  }
  triedToReconnect() {
    return this.monitor.reconnectAttempts > 0;
  }
  isProtocolSupported() {
    return indexOf2.call(supportedProtocols2, this.getProtocol()) >= 0;
  }
  isState(...states) {
    return indexOf2.call(states, this.getState()) >= 0;
  }
  getState() {
    if (this.webSocket) {
      for (let state in adapters.WebSocket) {
        if (adapters.WebSocket[state] === this.webSocket.readyState) {
          return state.toLowerCase();
        }
      }
    }
    return null;
  }
  installEventHandlers() {
    for (let eventName in this.events) {
      const handler = this.events[eventName].bind(this);
      this.webSocket[`on${eventName}`] = handler;
    }
  }
  uninstallEventHandlers() {
    for (let eventName in this.events) {
      this.webSocket[`on${eventName}`] = function() {
      };
    }
  }
}
Connection2.reopenDelay = 500;
Connection2.prototype.events = {
  message(event) {
    if (!this.isProtocolSupported()) {
      return;
    }
    const { identifier, message, reason, reconnect, type } = JSON.parse(event.data);
    this.monitor.recordMessage();
    switch (type) {
      case message_types2.welcome:
        if (this.triedToReconnect()) {
          this.reconnectAttempted = true;
        }
        this.monitor.recordConnect();
        return this.subscriptions.reload();
      case message_types2.disconnect:
        logger.log(`Disconnecting. Reason: ${reason}`);
        return this.close({
          allowReconnect: reconnect
        });
      case message_types2.ping:
        return null;
      case message_types2.confirmation:
        this.subscriptions.confirmSubscription(identifier);
        if (this.reconnectAttempted) {
          this.reconnectAttempted = false;
          return this.subscriptions.notify(identifier, "connected", {
            reconnected: true
          });
        } else {
          return this.subscriptions.notify(identifier, "connected", {
            reconnected: false
          });
        }
      case message_types2.rejection:
        return this.subscriptions.reject(identifier);
      default:
        return this.subscriptions.notify(identifier, "received", message);
    }
  },
  open() {
    logger.log(`WebSocket onopen event, using '${this.getProtocol()}' subprotocol`);
    this.disconnected = false;
    if (!this.isProtocolSupported()) {
      logger.log("Protocol is unsupported. Stopping monitor and disconnecting.");
      return this.close({
        allowReconnect: false
      });
    }
  },
  close(event) {
    logger.log("WebSocket onclose event");
    if (this.disconnected) {
      return;
    }
    this.disconnected = true;
    this.monitor.recordDisconnect();
    return this.subscriptions.notifyAll("disconnected", {
      willAttemptReconnect: this.monitor.isRunning()
    });
  },
  error() {
    logger.log("WebSocket onerror event");
  }
};
var extend3 = function(object, properties) {
  if (properties != null) {
    for (let key in properties) {
      const value = properties[key];
      object[key] = value;
    }
  }
  return object;
};

class Subscription2 {
  constructor(consumer2, params = {}, mixin) {
    this.consumer = consumer2;
    this.identifier = JSON.stringify(params);
    extend3(this, mixin);
  }
  perform(action, data = {}) {
    data.action = action;
    return this.send(data);
  }
  send(data) {
    return this.consumer.send({
      command: "message",
      identifier: this.identifier,
      data: JSON.stringify(data)
    });
  }
  unsubscribe() {
    return this.consumer.subscriptions.remove(this);
  }
}

class SubscriptionGuarantor2 {
  constructor(subscriptions) {
    this.subscriptions = subscriptions;
    this.pendingSubscriptions = [];
  }
  guarantee(subscription) {
    if (this.pendingSubscriptions.indexOf(subscription) == -1) {
      logger.log(`SubscriptionGuarantor guaranteeing ${subscription.identifier}`);
      this.pendingSubscriptions.push(subscription);
    } else {
      logger.log(`SubscriptionGuarantor already guaranteeing ${subscription.identifier}`);
    }
    this.startGuaranteeing();
  }
  forget(subscription) {
    logger.log(`SubscriptionGuarantor forgetting ${subscription.identifier}`);
    this.pendingSubscriptions = this.pendingSubscriptions.filter((s) => s !== subscription);
  }
  startGuaranteeing() {
    this.stopGuaranteeing();
    this.retrySubscribing();
  }
  stopGuaranteeing() {
    clearTimeout(this.retryTimeout);
  }
  retrySubscribing() {
    this.retryTimeout = setTimeout(() => {
      if (this.subscriptions && typeof this.subscriptions.subscribe === "function") {
        this.pendingSubscriptions.map((subscription) => {
          logger.log(`SubscriptionGuarantor resubscribing ${subscription.identifier}`);
          this.subscriptions.subscribe(subscription);
        });
      }
    }, 500);
  }
}

class Subscriptions2 {
  constructor(consumer2) {
    this.consumer = consumer2;
    this.guarantor = new SubscriptionGuarantor2(this);
    this.subscriptions = [];
  }
  create(channelName, mixin) {
    const channel = channelName;
    const params = typeof channel === "object" ? channel : {
      channel
    };
    const subscription = new Subscription2(this.consumer, params, mixin);
    return this.add(subscription);
  }
  add(subscription) {
    this.subscriptions.push(subscription);
    this.consumer.ensureActiveConnection();
    this.notify(subscription, "initialized");
    this.subscribe(subscription);
    return subscription;
  }
  remove(subscription) {
    this.forget(subscription);
    if (!this.findAll(subscription.identifier).length) {
      this.sendCommand(subscription, "unsubscribe");
    }
    return subscription;
  }
  reject(identifier) {
    return this.findAll(identifier).map((subscription) => {
      this.forget(subscription);
      this.notify(subscription, "rejected");
      return subscription;
    });
  }
  forget(subscription) {
    this.guarantor.forget(subscription);
    this.subscriptions = this.subscriptions.filter((s) => s !== subscription);
    return subscription;
  }
  findAll(identifier) {
    return this.subscriptions.filter((s) => s.identifier === identifier);
  }
  reload() {
    return this.subscriptions.map((subscription) => this.subscribe(subscription));
  }
  notifyAll(callbackName, ...args) {
    return this.subscriptions.map((subscription) => this.notify(subscription, callbackName, ...args));
  }
  notify(subscription, callbackName, ...args) {
    let subscriptions;
    if (typeof subscription === "string") {
      subscriptions = this.findAll(subscription);
    } else {
      subscriptions = [subscription];
    }
    return subscriptions.map((subscription2) => typeof subscription2[callbackName] === "function" ? subscription2[callbackName](...args) : undefined);
  }
  subscribe(subscription) {
    if (this.sendCommand(subscription, "subscribe")) {
      this.guarantor.guarantee(subscription);
    }
  }
  confirmSubscription(identifier) {
    logger.log(`Subscription confirmed ${identifier}`);
    this.findAll(identifier).map((subscription) => this.guarantor.forget(subscription));
  }
  sendCommand(subscription, command) {
    const { identifier } = subscription;
    return this.consumer.send({
      command,
      identifier
    });
  }
}

class Consumer2 {
  constructor(url) {
    this._url = url;
    this.subscriptions = new Subscriptions2(this);
    this.connection = new Connection2(this);
    this.subprotocols = [];
  }
  get url() {
    return createWebSocketURL2(this._url);
  }
  send(data) {
    return this.connection.send(data);
  }
  connect() {
    return this.connection.open();
  }
  disconnect() {
    return this.connection.close({
      allowReconnect: false
    });
  }
  ensureActiveConnection() {
    if (!this.connection.isActive()) {
      return this.connection.open();
    }
  }
  addSubProtocol(subprotocol) {
    this.subprotocols = [...this.subprotocols, subprotocol];
  }
}
function createWebSocketURL2(url) {
  if (typeof url === "function") {
    url = url();
  }
  if (url && !/^wss?:/i.test(url)) {
    const a = document.createElement("a");
    a.href = url;
    a.href = a.href;
    a.protocol = a.protocol.replace("http", "ws");
    return a.href;
  } else {
    return url;
  }
}
function createConsumer3(url = getConfig2("url") || INTERNAL.default_mount_path) {
  return new Consumer2(url);
}
function getConfig2(name) {
  const element = document.head.querySelector(`meta[name='action-cable-${name}']`);
  if (element) {
    return element.getAttribute("content");
  }
}

// app/javascript/controllers/message_form_controller.js
class message_form_controller_default extends Controller {
  static targets = ["highlight", "input", "filePreview", "dropzone", "replyBar", "replyAuthor", "replyPreview", "parentId"];
  static values = { channelId: String };
  connect() {
    this.consumer = createConsumer3();
    this.subscription = this.consumer.subscriptions.create({ channel: "ChannelChatChannel", channel_id: this.channelIdValue }, {
      received: (data) => this.handleReceived(data)
    });
    this.fileList = new DataTransfer;
    this.typingUsers = new Map;
    this._lastTypingSent = 0;
    this._submitting = false;
    const serverId = document.querySelector("[data-current-server-id]")?.dataset?.currentServerId;
    if (serverId) {
      try {
        localStorage.setItem(`lastChannel_${serverId}`, this.channelIdValue);
      } catch (e) {
      }
    }
    this.setupDragAndDrop();
    this.setupPaste();
    this.setupFileIntercept();
    this._replyHandler = (e) => {
      const { messageId, authorName, preview } = e.detail;
      if (this.hasParentIdTarget)
        this.parentIdTarget.value = messageId;
      if (this.hasReplyAuthorTarget)
        this.replyAuthorTarget.textContent = authorName;
      if (this.hasReplyPreviewTarget)
        this.replyPreviewTarget.textContent = preview;
      if (this.hasReplyBarTarget)
        this.replyBarTarget.classList.remove("hidden");
      this.inputTarget.focus();
    };
    this._reactHandler = (e) => {
      const { messageId } = e.detail;
      this.openReactionPickerForMessage(messageId);
    };
    document.addEventListener("inferno:reply", this._replyHandler);
    document.addEventListener("inferno:react", this._reactHandler);
    this._measureEmojiWidth();
    this._replaceEmojisWithPUA();
    this.updateHighlight();
    this._emojiMapReady = () => {
      this._replaceEmojisWithPUA();
      this.updateHighlight();
    };
    document.addEventListener("inferno:emoji-map-ready", this._emojiMapReady);
  }
  disconnect() {
    this.subscription?.unsubscribe();
    this.consumer?.disconnect();
    this.teardownDragAndDrop();
    this.teardownPaste();
    this.teardownFileIntercept();
    if (this._emojiMapReady)
      document.removeEventListener("inferno:emoji-map-ready", this._emojiMapReady);
    if (this._replyHandler)
      document.removeEventListener("inferno:reply", this._replyHandler);
    if (this._reactHandler)
      document.removeEventListener("inferno:react", this._reactHandler);
    if (this.typingUsers) {
      this.typingUsers.forEach((u) => clearTimeout(u.timeout));
      this.typingUsers.clear();
    }
  }
  setupPaste() {
    this._pasteHandler = (e) => {
      const items = e.clipboardData?.items;
      if (!items)
        return;
      if (e.clipboardData.types.includes("text/plain") || e.clipboardData.types.includes("text/html"))
        return;
      const files = [];
      for (const item of items) {
        if (item.kind === "file" && item.type.startsWith("image/")) {
          const file = item.getAsFile();
          if (file)
            files.push(file);
        }
      }
      if (files.length > 0) {
        e.preventDefault();
        this.addFiles(files);
      }
    };
    this.element.addEventListener("paste", this._pasteHandler);
  }
  teardownPaste() {
    if (this._pasteHandler) {
      this.element.removeEventListener("paste", this._pasteHandler);
    }
  }
  setupFileIntercept() {
    const form = this.element.querySelector("form");
    if (!form)
      return;
    this._fileInterceptHandler = (event) => {
      const body = event.detail.fetchOptions.body;
      if (body instanceof FormData) {
        const content = body.get("message[content]");
        if (content && window._emojiReverse) {
          body.set("message[content]", content.replace(/\u2003([\uE000-\uF8FF])/g, (m, ch, offset, str) => {
            const name = window._emojiReverse[ch];
            if (!name)
              return m;
            const next = str[offset + m.length];
            return `:${name}:` + (next === " " ? " " : "");
          }));
        }
        if (this.fileList.files.length > 0) {
          body.delete("message[files][]");
          for (const file of this.fileList.files) {
            body.append("message[files][]", file);
          }
        }
      }
    };
    form.addEventListener("turbo:before-fetch-request", this._fileInterceptHandler);
  }
  teardownFileIntercept() {
    const form = this.element.querySelector("form");
    if (form && this._fileInterceptHandler) {
      form.removeEventListener("turbo:before-fetch-request", this._fileInterceptHandler);
    }
  }
  setupDragAndDrop() {
    this._dragCounter = 0;
    this._dragEnter = (e) => {
      e.preventDefault();
      if (!e.dataTransfer?.types?.includes("Files"))
        return;
      this._dragCounter++;
      if (this._dragCounter === 1)
        this.dropzoneTarget.classList.remove("hidden");
    };
    this._dragOver = (e) => {
      e.preventDefault();
    };
    this._dragLeave = (e) => {
      e.preventDefault();
      if (!e.dataTransfer?.types?.includes("Files"))
        return;
      this._dragCounter--;
      if (this._dragCounter <= 0) {
        this._dragCounter = 0;
        this.dropzoneTarget.classList.add("hidden");
      }
    };
    this._drop = (e) => {
      e.preventDefault();
      this._dragCounter = 0;
      this.dropzoneTarget.classList.add("hidden");
      if (e.dataTransfer.files.length) {
        this.addFiles(e.dataTransfer.files);
      }
    };
    document.addEventListener("dragenter", this._dragEnter);
    document.addEventListener("dragover", this._dragOver);
    document.addEventListener("dragleave", this._dragLeave);
    document.addEventListener("drop", this._drop);
  }
  teardownDragAndDrop() {
    document.removeEventListener("dragenter", this._dragEnter);
    document.removeEventListener("dragover", this._dragOver);
    document.removeEventListener("dragleave", this._dragLeave);
    document.removeEventListener("drop", this._drop);
  }
  handleFileSelect(event) {
    this.addFiles(event.target.files);
    event.target.value = "";
    this.syncFileInput();
  }
  addFiles(files) {
    for (const file of files) {
      this.fileList.items.add(file);
    }
    this.syncFileInput();
    this.renderPreviews();
  }
  removeFile(event) {
    const index = parseInt(event.currentTarget.dataset.index);
    this.fileList.items.remove(index);
    this.syncFileInput();
    this.renderPreviews();
  }
  syncFileInput() {
    const input = this.element.querySelector("input[type=file]");
    if (input)
      input.files = this.fileList.files;
  }
  renderPreviews() {
    const container = this.filePreviewTarget;
    container.innerHTML = "";
    if (this.fileList.files.length === 0) {
      container.classList.add("hidden");
      return;
    }
    container.classList.remove("hidden");
    Array.from(this.fileList.files).forEach((file, i) => {
      const wrapper = document.createElement("div");
      wrapper.className = "relative inline-flex items-center bg-gray-700 rounded-lg p-2 mr-2 mb-2";
      if (file.type.startsWith("image/")) {
        const img = document.createElement("img");
        img.className = "w-16 h-16 object-cover rounded";
        img.src = URL.createObjectURL(file);
        wrapper.appendChild(img);
      } else {
        const name = document.createElement("span");
        name.className = "text-xs text-gray-200 max-w-[100px] truncate";
        name.textContent = file.name;
        wrapper.appendChild(name);
      }
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "absolute -top-1.5 -right-1.5 w-5 h-5 bg-red-600 hover:bg-red-500 rounded-full flex items-center justify-center text-white text-xs cursor-pointer";
      btn.innerHTML = "&times;";
      btn.dataset.index = i;
      btn.dataset.action = "click->message-form#removeFile";
      wrapper.appendChild(btn);
      container.appendChild(wrapper);
    });
  }
  setReply(event) {
    const btn = event.currentTarget;
    const messageId = btn.dataset.messageId;
    const authorName = btn.dataset.authorName;
    const preview = btn.dataset.preview;
    this.parentIdTarget.value = messageId;
    this.replyAuthorTarget.textContent = authorName;
    this.replyPreviewTarget.textContent = preview;
    this.replyBarTarget.classList.remove("hidden");
    this.inputTarget.focus();
  }
  clearReply() {
    this.parentIdTarget.value = "";
    this.replyBarTarget.classList.add("hidden");
  }
  sendTyping() {
    if (!this.inputTarget.value.trim())
      return;
    const now3 = Date.now();
    if (now3 - this._lastTypingSent < 2000)
      return;
    this._lastTypingSent = now3;
    this.subscription.perform("typing");
  }
  _ensureTypingStyles() {
    if (document.getElementById("typing-dots-style"))
      return;
    const style = document.createElement("style");
    style.id = "typing-dots-style";
    style.textContent = `
      .typing-dots span {
        animation: typingDot 1.4s infinite;
        display: inline-block;
      }
      .typing-dots span:nth-child(2) { animation-delay: 0.2s; }
      .typing-dots span:nth-child(3) { animation-delay: 0.4s; }
      @keyframes typingDot {
        0%, 60%, 100% { opacity: 0.3; }
        30% { opacity: 1; }
      }
    `;
    document.head.appendChild(style);
  }
  _renderTypingIndicator() {
    const el = document.getElementById("typing-indicator");
    if (!el)
      return;
    const users = Array.from(this.typingUsers.values()).map((v) => v.username);
    if (users.length === 0) {
      el.innerHTML = "";
      return;
    }
    this._ensureTypingStyles();
    const dots = '<span class="typing-dots"><span>.</span><span>.</span><span>.</span></span>';
    let text;
    if (users.length === 1) {
      text = `<strong>${users[0]}</strong> is typing${dots}`;
    } else if (users.length === 2) {
      text = `<strong>${users[0]}</strong> and <strong>${users[1]}</strong> are typing${dots}`;
    } else if (users.length === 3) {
      text = `<strong>${users[0]}</strong>, <strong>${users[1]}</strong>, and <strong>${users[2]}</strong> are typing${dots}`;
    } else {
      text = `Several people are typing${dots}`;
    }
    el.innerHTML = text;
  }
  handleKeydown(event) {
    if (this._handleEmojiKeydown(event))
      return;
    if (event.key === "Enter" && !event.shiftKey) {
      const content = this.inputTarget.value;
      const backtickCount = (content.match(/`{3}/g) || []).length;
      if (backtickCount % 2 === 1) {
        return;
      }
      event.preventDefault();
      if (this._submitting)
        return;
      const trimmed = content.trim();
      const fileInput = this.element.querySelector("input[type=file]");
      const hasFiles = fileInput && fileInput.files.length > 0;
      if (!trimmed && !hasFiles)
        return;
      this._submitting = true;
      const form = event.target.closest("form");
      if (form)
        form.requestSubmit();
    }
  }
  handleSubmit(event) {
    this._submitting = false;
    if (event.detail.success) {
      this.inputTarget.value = "";
      this.updateHighlight();
      this.inputTarget.style.height = "auto";
      this.inputTarget.style.fontFamily = "";
      this.inputTarget.style.fontSize = "";
      if (this.inputTarget.parentElement)
        this.inputTarget.parentElement.style.backgroundColor = "";
      this.fileList = new DataTransfer;
      this.syncFileInput();
      this.renderPreviews();
      this.clearReply();
    }
  }
  autoResize() {
    this._replaceEmojisWithPUA();
    this.updateHighlight();
    const input = this.inputTarget;
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 192) + "px";
    this.updateCodeBlockStyle();
  }
  updateCodeBlockStyle() {
    const input = this.inputTarget;
    const val = input.value;
    const tripleCount = (val.match(/`{3}/g) || []).length;
    const inCodeBlock = tripleCount % 2 === 1;
    if (inCodeBlock) {
      input.style.fontFamily = "Consolas, Monaco, 'Courier New', monospace";
      input.style.fontSize = "0.8rem";
      if (input.parentElement)
        input.parentElement.style.backgroundColor = "rgb(30 31 34)";
    } else {
      input.style.fontFamily = "";
      input.style.fontSize = "";
      if (input.parentElement)
        input.parentElement.style.backgroundColor = "";
    }
  }
  handleReceived(data) {
    const messagesDiv = document.getElementById("messages");
    if (!messagesDiv)
      return;
    switch (data.type) {
      case "new_message": {
        const welcome = messagesDiv.querySelector(".text-center");
        if (welcome)
          welcome.remove();
        const scrollCtrl = this.application.getControllerForElementAndIdentifier(messagesDiv, "scroll-position");
        if (scrollCtrl && scrollCtrl.hasNewerValue) {
          scrollCtrl.showNewMessageBar();
        } else {
          messagesDiv.insertAdjacentHTML("beforeend", data.html);
          const allMsgs = messagesDiv.querySelectorAll("[data-message-id]");
          if (allMsgs.length > 0) {
            this.applyGrouping(allMsgs[allMsgs.length - 1]);
          }
          if (scrollCtrl) {
            const allMsgIds = messagesDiv.querySelectorAll("[id^='message_']");
            if (allMsgIds.length > 0) {
              scrollCtrl.newestMessageIdValue = allMsgIds[allMsgIds.length - 1].id.replace("message_", "");
            }
          }
        }
        break;
      }
      case "update_message":
        const existing = document.getElementById(`message_${data.message_id}`);
        if (existing)
          existing.outerHTML = data.html;
        break;
      case "update_message_content":
        const target = document.getElementById(`message_${data.message_id}`);
        if (target) {
          const contentDiv = target.querySelector(".message-content");
          if (contentDiv)
            contentDiv.innerHTML = data.html;
        }
        break;
      case "delete_message":
        const toDelete = document.getElementById(`message_${data.message_id}`);
        if (toDelete)
          toDelete.remove();
        break;
      case "update_reactions":
        const msgEl = document.getElementById(`message_${data.message_id}`);
        if (msgEl) {
          const reactionsContainer = msgEl.querySelector(".reactions-container");
          if (reactionsContainer)
            reactionsContainer.outerHTML = data.html;
        }
        break;
      case "typing": {
        const selfId = document.body.dataset.currentUserId;
        if (String(data.user_id) === String(selfId))
          break;
        const existing2 = this.typingUsers.get(data.user_id);
        if (existing2)
          clearTimeout(existing2.timeout);
        const timeout = setTimeout(() => {
          this.typingUsers.delete(data.user_id);
          this._renderTypingIndicator();
        }, 3000);
        this.typingUsers.set(data.user_id, { username: data.username, timeout });
        this._renderTypingIndicator();
        break;
      }
    }
  }
  applyGrouping(messageEl) {
    const prev = messageEl.previousElementSibling;
    if (!prev || !prev.dataset.messageId)
      return;
    const sameAuthor = messageEl.dataset.authorId === prev.dataset.authorId;
    const isSystem = messageEl.dataset.systemMessage === "true";
    const prevIsSystem = prev.dataset.systemMessage === "true";
    const isReply = messageEl.dataset.isReply === "true";
    const prevIsReply = prev.dataset.isReply === "true";
    if (!sameAuthor || isSystem || prevIsSystem || isReply || prevIsReply)
      return;
    const ts = new Date(messageEl.dataset.timestamp);
    const prevTs = new Date(prev.dataset.timestamp);
    if (ts - prevTs >= 300000)
      return;
    messageEl.classList.add("message-grouped");
    const avatarDiv = messageEl.querySelector(":scope > .shrink-0");
    if (avatarDiv) {
      const time = ts.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
      avatarDiv.innerHTML = `<span class="text-[10px] text-gray-500 opacity-0 group-hover:opacity-100">${time}</span>`;
      avatarDiv.className = "shrink-0 mt-0.5 mr-4 w-10 flex items-center justify-center";
    }
    const contentDiv = messageEl.querySelector(":scope > .flex-1");
    if (contentDiv) {
      const header = contentDiv.querySelector(":scope > .flex.items-baseline");
      if (header)
        header.style.display = "none";
    }
  }
  toggleReaction(event) {
    const btn = event.currentTarget;
    const messageId = btn.dataset.messageId;
    const emoji = btn.dataset.emoji;
    const token = document.querySelector("meta[name=csrf-token]")?.content;
    const formData = new FormData;
    formData.append("emoji", emoji);
    fetch(`/channels/${this.channelIdValue}/messages/${messageId}/toggle_reaction`, {
      method: "POST",
      headers: { "X-CSRF-Token": token },
      body: formData
    });
  }
  openReactionPickerForMessage(messageId) {
    const existing = document.getElementById("reaction-picker-popup");
    if (existing)
      existing.remove();
    const common = ["\uD83D\uDE00", "\uD83D\uDE02", "❤️", "\uD83D\uDC4D", "\uD83D\uDC4E", "\uD83D\uDE2E", "\uD83D\uDE22", "\uD83D\uDE21", "\uD83D\uDE0D", "\uD83E\uDD14", "\uD83D\uDE4F", "\uD83D\uDE4C", "\uD83D\uDD25", "\uD83C\uDF89", "✨", "\uD83D\uDCAF", "\uD83D\uDC80", "\uD83E\uDD23", "\uD83D\uDE0E", "\uD83D\uDE44"];
    const popup = document.createElement("div");
    popup.id = "reaction-picker-popup";
    popup.className = "fixed z-50 bg-gray-800 border border-gray-700 rounded-lg shadow-xl p-2 flex flex-wrap gap-0.5 w-64";
    const msgEl = document.getElementById(`message_${messageId}`);
    if (msgEl) {
      const rect = msgEl.getBoundingClientRect();
      const popupHeight = 120;
      if (rect.top > popupHeight + 10) {
        popup.style.top = rect.top - popupHeight - 4 + "px";
      } else {
        popup.style.top = rect.bottom + 4 + "px";
      }
      popup.style.right = "80px";
    } else {
      popup.style.top = "50%";
      popup.style.left = "50%";
      popup.style.transform = "translate(-50%, -50%)";
    }
    const channelId = this.channelIdValue;
    common.forEach((emoji) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "w-8 h-8 flex items-center justify-center text-xl hover:bg-gray-700 rounded cursor-pointer";
      b.textContent = emoji;
      b.onclick = () => {
        popup.remove();
        const token = document.querySelector("meta[name=csrf-token]")?.content;
        const fd = new FormData;
        fd.append("emoji", emoji);
        fetch(`/channels/${channelId}/messages/${messageId}/toggle_reaction`, {
          method: "POST",
          headers: { "X-CSRF-Token": token },
          body: fd
        });
      };
      popup.appendChild(b);
    });
    document.body.appendChild(popup);
    setTimeout(() => {
      const handler = (e) => {
        if (!popup.contains(e.target)) {
          popup.remove();
          document.removeEventListener("click", handler);
        }
      };
      document.addEventListener("click", handler);
    }, 0);
  }
  openReactionPicker(event) {
    const messageId = event.currentTarget.dataset.messageId;
    this.openReactionPickerForMessage(messageId);
  }
  updateHighlight() {
    if (!this.hasHighlightTarget)
      return;
    const text = this.inputTarget.value;
    let html = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    html = html.replace(/(https?:\/\/[^\s<>]+)/gi, '<span class="text-blue-400">$1</span>');
    html = html.replace(/\*\*(.+?)\*\*/g, '<span class="text-white font-bold">**$1**</span>');
    html = html.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, '<span class="text-white italic">*$1*</span>');
    html = html.replace(/~~(.+?)~~/g, '<span class="text-gray-400 line-through">~~$1~~</span>');
    html = html.replace(/`([^`]+)`/g, '<span class="text-orange-300 bg-gray-700/50 rounded px-0.5">`$1`</span>');
    html = html.replace(/(```[\s\S]*?```)/g, '<span class="text-orange-300">$1</span>');
    if (window._emojiReverse && window._emojiMap) {
      html = html.replace(/\u2003([\uE000-\uF8FF])/g, (_, ch) => {
        const name = window._emojiReverse[ch];
        if (name && window._emojiMap[name]) {
          const w = this._emojiCharWidth || 20;
          return `<img src="${window._emojiMap[name]}" style="display:inline;height:${w}px;width:${w}px;object-fit:contain;vertical-align:middle;pointer-events:none">`;
        }
        return _;
      });
    }
    if (html.endsWith(`
`))
      html += "&nbsp;";
    this.highlightTarget.innerHTML = html;
    this.highlightTarget.scrollTop = this.inputTarget.scrollTop;
  }
  _measureEmojiWidth() {
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d");
    const cs = getComputedStyle(this.inputTarget);
    ctx.font = `${cs.fontSize} ${cs.fontFamily}`;
    this._emojiCharWidth = ctx.measureText(" ").width;
  }
  _replaceEmojisWithPUA() {
    if (!window._emojiPUA || !window._emojiMap)
      return;
    const input = this.inputTarget;
    const val = input.value;
    if (!val.includes(":"))
      return;
    const selStart = input.selectionStart;
    const selEnd = input.selectionEnd;
    let newVal = "";
    let i = 0;
    let newStart = selStart;
    let newEnd = selEnd;
    while (i < val.length) {
      if (val[i] === ":") {
        const rest = val.substring(i + 1);
        const match = rest.match(/^([a-z0-9_]+):/);
        if (match && window._emojiPUA[match[1]]) {
          const fullLen = match[0].length + 1;
          const mEnd = i + fullLen;
          const replacement = " " + window._emojiPUA[match[1]];
          const reduction = fullLen - 2;
          newVal += replacement;
          if (selStart >= mEnd)
            newStart -= reduction;
          else if (selStart > i)
            newStart = newVal.length;
          if (selEnd >= mEnd)
            newEnd -= reduction;
          else if (selEnd > i)
            newEnd = newVal.length;
          i = mEnd;
          continue;
        }
      }
      newVal += val[i];
      i++;
    }
    if (newVal === val)
      return;
    input.value = newVal;
    input.selectionStart = Math.max(0, newStart);
    input.selectionEnd = Math.max(0, newEnd);
  }
  _handleEmojiKeydown(event) {
    if (!window._emojiReverse)
      return false;
    const input = this.inputTarget;
    const val = input.value;
    const pos = input.selectionStart;
    if (pos !== input.selectionEnd)
      return false;
    if (event.key === "Backspace") {
      if (pos >= 2 && val[pos - 2] === " " && window._emojiReverse[val[pos - 1]]) {
        event.preventDefault();
        input.value = val.substring(0, pos - 2) + val.substring(pos);
        input.selectionStart = input.selectionEnd = pos - 2;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
      }
    } else if (event.key === "Delete") {
      if (pos <= val.length - 2 && val[pos] === " " && window._emojiReverse[val[pos + 1]]) {
        event.preventDefault();
        input.value = val.substring(0, pos) + val.substring(pos + 2);
        input.selectionStart = input.selectionEnd = pos;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
      }
    } else if (event.key === "ArrowLeft" && !event.shiftKey) {
      if (pos >= 2 && val[pos - 2] === " " && window._emojiReverse[val[pos - 1]]) {
        event.preventDefault();
        input.selectionStart = input.selectionEnd = pos - 2;
        return true;
      }
      if (pos >= 1 && val[pos - 1] === " " && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault();
        input.selectionStart = input.selectionEnd = pos - 1;
        return true;
      }
    } else if (event.key === "ArrowRight" && !event.shiftKey) {
      if (pos <= val.length - 2 && val[pos] === " " && window._emojiReverse[val[pos + 1]]) {
        event.preventDefault();
        input.selectionStart = input.selectionEnd = pos + 2;
        return true;
      }
      if (pos > 0 && val[pos - 1] === " " && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault();
        input.selectionStart = input.selectionEnd = pos + 1;
        return true;
      }
    }
    return false;
  }
}

// app/javascript/controllers/scroll_position_controller.js
var DOM_CAP = 150;
class scroll_position_controller_default extends Controller {
  static values = {
    channelId: String,
    serverId: String,
    oldestMessageId: String,
    hasOlder: Boolean,
    newestMessageId: String,
    hasNewer: Boolean
  };
  static targets = ["newMessageBar"];
  connect() {
    this.newMessageCount = 0;
    this._initializing = true;
    this._lastScrollTop = 0;
    this._lastAnchorId = null;
    this._loadingOlder = false;
    this._loadingNewer = false;
    this._onBeforeFrameRender = (e) => {
      if (e.target.id === "main-content") {
        const pos = this.element.scrollTop || this._lastScrollTop;
        if (pos > 0)
          this._forceSave(pos);
      }
    };
    document.addEventListener("turbo:before-frame-render", this._onBeforeFrameRender);
    this._onLinkClick = (e) => {
      const a = e.target.closest("a[href]");
      if (!a)
        return;
      const href = a.getAttribute("href");
      if (!href)
        return;
      const match = href.match(/(?:https?:\/\/[^\/]+)?\/servers\/([a-zA-Z0-9]+)\/channels\/([a-zA-Z0-9]+)#message[-_]([a-zA-Z0-9]+)/);
      if (!match)
        return;
      e.preventDefault();
      e.stopPropagation();
      const [, sId, cId, mId] = match;
      const currentEl = document.querySelector("[data-current-channel-id]");
      const currentChannelId = currentEl ? currentEl.dataset.currentChannelId : null;
      if (currentChannelId === cId) {
        const el = document.getElementById(`message_${mId}`);
        if (el) {
          el.scrollIntoView({ behavior: "smooth", block: "center" });
          this.highlightMessage(el, true);
        }
      } else {
        const url = `/servers/${sId}/channels/${cId}`;
        sessionStorage.setItem("jump_to_message", mId);
        window.Turbo.visit(url);
      }
    };
    document.addEventListener("click", this._onLinkClick, true);
    const pendingJump = sessionStorage.getItem("jump_to_message");
    if (pendingJump) {
      sessionStorage.removeItem("jump_to_message");
      this._jumpToMessage(pendingJump);
    } else {
      const hash = window.location.hash;
      const messageMatch = hash.match(/^#message[-_]([a-zA-Z0-9]+)$/);
      if (messageMatch) {
        history.replaceState(null, "", window.location.pathname + window.location.search);
        this._jumpToMessage(messageMatch[1]);
      } else {
        this._restoreScroll();
      }
    }
    this._onScroll = () => {
      this._lastScrollTop = this.element.scrollTop;
      if (!this.isNearBottom())
        this._keepingBottom = false;
      if (this.isNearBottom())
        this.hideNewMessageBar();
      if (this.isNearTop() && !this._initializing) {
        this.loadOlderMessages();
      }
      if (this.isNearBottom() && this.hasNewerValue && !this._initializing) {
        this.loadNewerMessages();
      }
    };
    this.element.addEventListener("scroll", this._onScroll);
    this._saveInterval = setInterval(() => {
      this.savePosition(this._lastScrollTop);
    }, 1000);
    const bar = this.element.parentElement?.querySelector("[data-scroll-position-target=newMessageBar]");
    if (bar) {
      const btn = bar.querySelector("button");
      if (btn) {
        this._jumpHandler = () => this.jumpToBottom();
        btn.addEventListener("click", this._jumpHandler);
        this._jumpBtn = btn;
      }
    }
    this.observer = new MutationObserver((mutations) => {
      if (this._initializing || this._suppressObserver)
        return;
      const newMessages = [];
      for (const m of mutations) {
        for (const n of m.addedNodes) {
          if (n.nodeType === 1 && n.id?.startsWith("message_"))
            newMessages.push(n);
        }
      }
      if (!newMessages.length)
        return;
      const wasNearBottom = this.isNearBottom();
      if (wasNearBottom) {
        this.scrollToBottom();
        for (const msg of newMessages) {
          msg.querySelectorAll("img").forEach((img) => {
            if (!img.complete) {
              img.addEventListener("load", () => {
                if (this.isNearBottom())
                  this.scrollToBottom();
              }, { once: true });
            }
          });
        }
      } else {
        this.showNewMessageBar();
      }
    });
    this.observer.observe(this.element, { childList: true });
    this.element.querySelectorAll("img").forEach((img) => {
      if (!img.complete) {
        img.addEventListener("load", () => {
          if (this._initializing)
            return;
          if (this.isNearBottom()) {
            this.scrollToBottom();
          } else if (this._restoredAnchorEl?.isConnected) {
            this._restoredAnchorEl.scrollIntoView({ block: "center" });
            this._lastScrollTop = this.element.scrollTop;
          }
        }, { once: true });
      }
    });
  }
  _restoreScroll() {
    const savedAnchor = this.getSavedAnchor();
    if (savedAnchor === "__bottom__") {
      this.scrollToBottom();
      this._lastAnchorId = "__bottom__";
      this._keepAtBottom();
      this._finishInit();
      return;
    }
    if (savedAnchor) {
      const el = document.getElementById(`message_${savedAnchor}`);
      if (el) {
        this._restoredAnchorEl = el;
        el.scrollIntoView({ block: "center" });
        this._lastScrollTop = this.element.scrollTop;
        this._finishInit();
        return;
      }
      this.clearSavedAnchor();
      this._lastAnchorId = null;
    }
    const saved = this.getSavedPosition();
    if (saved !== null && saved > 0) {
      this.element.scrollTop = saved;
      this._lastScrollTop = saved;
      if (this.isNearBottom()) {
        this.scrollToBottom();
        this._lastAnchorId = "__bottom__";
      }
    } else {
      this.scrollToBottom();
      this._lastAnchorId = "__bottom__";
    }
    this._finishInit();
  }
  _jumpToMessage(messageId) {
    const el = document.getElementById(`message_${messageId}`);
    if (el) {
      el.scrollIntoView({ behavior: "smooth", block: "center" });
      this._lastScrollTop = this.element.scrollTop;
      this.highlightMessage(el, true);
      this._finishInit();
    } else {
      this.waitForMessage(messageId, (msgEl) => {
        msgEl.scrollIntoView({ behavior: "smooth", block: "center" });
        this._lastScrollTop = this.element.scrollTop;
        this.highlightMessage(msgEl, true);
        this._finishInit();
      });
    }
  }
  _finishInit() {
    requestAnimationFrame(() => {
      this._initializing = false;
      this._eagerLoadVisibleImages();
    });
  }
  _eagerLoadVisibleImages() {
    const rect = this.element.getBoundingClientRect();
    this.element.querySelectorAll('img[loading="lazy"]').forEach((img) => {
      if (img.complete)
        return;
      const imgRect = img.getBoundingClientRect();
      if (imgRect.bottom >= rect.top - 200 && imgRect.top <= rect.bottom + 200) {
        img.loading = "eager";
      }
    });
  }
  highlightMessage(el, afterScroll = false) {
    const doHighlight = () => {
      el.style.backgroundColor = "rgba(99, 102, 241, 0.3)";
      el.style.borderRadius = "4px";
      setTimeout(() => {
        el.style.transition = "background-color 0.8s ease-out";
        el.style.backgroundColor = "transparent";
        setTimeout(() => {
          el.style.backgroundColor = "";
          el.style.borderRadius = "";
          el.style.transition = "";
        }, 800);
      }, 1000);
    };
    if (afterScroll) {
      setTimeout(doHighlight, 600);
    } else {
      doHighlight();
    }
  }
  waitForMessage(messageId, callback, timeoutMs = 5000) {
    const el = document.getElementById(`message_${messageId}`);
    if (el) {
      callback(el);
      return;
    }
    const obs = new MutationObserver((mutations, observer) => {
      const el2 = document.getElementById(`message_${messageId}`);
      if (el2) {
        observer.disconnect();
        callback(el2);
      }
    });
    obs.observe(this.element, { childList: true, subtree: true });
    setTimeout(() => {
      obs.disconnect();
      const el2 = document.getElementById(`message_${messageId}`);
      if (el2)
        callback(el2);
      else
        this.scrollToBottom();
    }, timeoutMs);
  }
  _forceSave(pos) {
    try {
      const positions = JSON.parse(sessionStorage.getItem("channel_scroll") || "{}");
      positions[this.channelIdValue] = pos;
      sessionStorage.setItem("channel_scroll", JSON.stringify(positions));
      if (this._lastAnchorId) {
        sessionStorage.setItem("channel_anchor_" + this.channelIdValue, this._lastAnchorId);
      }
    } catch {
    }
  }
  disconnect() {
    if (this._lastScrollTop > 0)
      this._forceSave(this._lastScrollTop);
    document.removeEventListener("turbo:before-frame-render", this._onBeforeFrameRender);
    document.removeEventListener("click", this._onLinkClick, true);
    if (this._jumpBtn && this._jumpHandler) {
      this._jumpBtn.removeEventListener("click", this._jumpHandler);
    }
    this.observer?.disconnect();
    try {
      this.element.removeEventListener("scroll", this._onScroll);
    } catch {
    }
    clearInterval(this._saveInterval);
  }
  _keepAtBottom() {
    this._keepingBottom = true;
    const snap = () => {
      if (this._keepingBottom)
        this.scrollToBottom();
    };
    this.element.querySelectorAll("img, iframe, video").forEach((el) => {
      if (el.tagName === "IMG" && !el.complete) {
        el.addEventListener("load", snap, { once: true });
      } else if (el.tagName === "IFRAME") {
        el.addEventListener("load", snap, { once: true });
      } else if (el.tagName === "VIDEO") {
        el.addEventListener("loadedmetadata", snap, { once: true });
      }
    });
    let count = 0;
    const tick = () => {
      if (!this._keepingBottom || count++ >= 8)
        return;
      this.scrollToBottom();
      setTimeout(tick, 250);
    };
    setTimeout(tick, 250);
  }
  scrollToBottom() {
    this.element.scrollTop = this.element.scrollHeight;
    this._lastScrollTop = this.element.scrollTop;
    this.hideNewMessageBar();
  }
  jumpToBottom() {
    this.clearSavedAnchor();
    if (this.hasNewerValue) {
      const serverId = this.serverIdValue;
      const channelId = this.channelIdValue;
      window.Turbo.visit(`/servers/${serverId}/channels/${channelId}`);
    } else {
      this.scrollToBottom();
    }
  }
  isNearBottom() {
    const threshold = 150;
    return this.element.scrollHeight - this.element.scrollTop - this.element.clientHeight < threshold;
  }
  isNearTop() {
    return this.element.scrollTop < 200;
  }
  _findAnchorMessage() {
    const messages = this.element.querySelectorAll("[id^='message_']");
    const containerRect = this.element.getBoundingClientRect();
    const centerY = containerRect.top + containerRect.height / 2;
    let closest = null;
    let closestDist = Infinity;
    for (const msg of messages) {
      const rect = msg.getBoundingClientRect();
      if (rect.bottom < containerRect.top || rect.top > containerRect.bottom)
        continue;
      const msgCenter = rect.top + rect.height / 2;
      const dist = Math.abs(msgCenter - centerY);
      if (dist < closestDist) {
        closestDist = dist;
        closest = { element: msg, offsetTop: rect.top };
      }
    }
    return closest;
  }
  _restoreAnchor(anchor) {
    if (!anchor || !anchor.element.isConnected)
      return;
    const newTop = anchor.element.getBoundingClientRect().top;
    const drift = newTop - anchor.offsetTop;
    this.element.scrollTop += drift;
  }
  _getMessageElements() {
    return this.element.querySelectorAll("[id^='message_']");
  }
  trimBottom() {
    const messages = this._getMessageElements();
    if (messages.length <= DOM_CAP)
      return;
    const anchor = this._findAnchorMessage();
    const toRemove = messages.length - DOM_CAP;
    for (let i = messages.length - 1;i >= messages.length - toRemove; i--) {
      messages[i].remove();
    }
    const remaining = this._getMessageElements();
    if (remaining.length > 0) {
      this.newestMessageIdValue = remaining[remaining.length - 1].id.replace("message_", "");
    }
    this.hasNewerValue = true;
    this._bottomTrimCount = (this._bottomTrimCount || 0) + 1;
    if (this._bottomTrimCount >= 2) {
      this.showNewMessageBar("Jump to Present");
    }
    this._restoreAnchor(anchor);
  }
  trimTop() {
    const messages = this._getMessageElements();
    if (messages.length <= DOM_CAP)
      return;
    const anchor = this._findAnchorMessage();
    const toRemove = messages.length - DOM_CAP;
    for (let i = 0;i < toRemove; i++) {
      messages[i].remove();
    }
    const remaining = this._getMessageElements();
    if (remaining.length > 0) {
      this.oldestMessageIdValue = remaining[0].id.replace("message_", "");
    }
    this.hasOlderValue = true;
    this._restoreAnchor(anchor);
  }
  async loadOlderMessages() {
    if (this._loadingOlder || !this.hasOlderValue || !this.oldestMessageIdValue)
      return;
    this._loadingOlder = true;
    const serverId = this.serverIdValue;
    const channelId = this.channelIdValue;
    const beforeId = this.oldestMessageIdValue;
    const url = `/servers/${serverId}/channels/${channelId}/older_messages?before=${beforeId}`;
    try {
      const response = await fetch(url, {
        headers: {
          Accept: "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      });
      if (!response.ok)
        return;
      const html = await response.text();
      if (!html.trim()) {
        this.hasOlderValue = false;
        return;
      }
      this._suppressObserver = true;
      const anchor = this._findAnchorMessage();
      const template = document.createElement("template");
      template.innerHTML = html;
      const firstChild = this.element.firstChild;
      while (template.content.firstChild) {
        this.element.insertBefore(template.content.firstChild, firstChild);
      }
      this._restoreAnchor(anchor);
      const allMessages = this._getMessageElements();
      if (allMessages.length > 0) {
        this.oldestMessageIdValue = allMessages[0].id.replace("message_", "");
      }
      const hasMore = response.headers.get("X-Has-Older");
      if (hasMore === "false") {
        this.hasOlderValue = false;
      }
      this.trimBottom();
      setTimeout(() => {
        this._suppressObserver = false;
      }, 0);
      this._bindImageLoadHandlers();
    } catch (e) {
      this._suppressObserver = false;
      console.error("Failed to load older messages:", e);
    } finally {
      this._loadingOlder = false;
    }
  }
  async loadNewerMessages() {
    if (this._loadingNewer || !this.hasNewerValue || !this.newestMessageIdValue)
      return;
    this._loadingNewer = true;
    const serverId = this.serverIdValue;
    const channelId = this.channelIdValue;
    const afterId = this.newestMessageIdValue;
    const url = `/servers/${serverId}/channels/${channelId}/newer_messages?after=${afterId}`;
    try {
      const response = await fetch(url, {
        headers: {
          Accept: "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      });
      if (!response.ok)
        return;
      const html = await response.text();
      if (!html.trim()) {
        this.hasNewerValue = false;
        return;
      }
      this._suppressObserver = true;
      const anchor = this._findAnchorMessage();
      const template = document.createElement("template");
      template.innerHTML = html;
      while (template.content.firstChild) {
        this.element.appendChild(template.content.firstChild);
      }
      this._restoreAnchor(anchor);
      const allMessages = this._getMessageElements();
      if (allMessages.length > 0) {
        this.newestMessageIdValue = allMessages[allMessages.length - 1].id.replace("message_", "");
      }
      const hasNewer = response.headers.get("X-Has-Newer");
      if (hasNewer === "false") {
        this.hasNewerValue = false;
      }
      this.trimTop();
      setTimeout(() => {
        this._suppressObserver = false;
      }, 0);
      this._bindImageLoadHandlers();
    } catch (e) {
      this._suppressObserver = false;
      console.error("Failed to load newer messages:", e);
    } finally {
      this._loadingNewer = false;
    }
  }
  _bindImageLoadHandlers() {
    this.element.querySelectorAll("img").forEach((img) => {
      if (!img.complete) {
        img.addEventListener("load", () => {
          if (this.isNearBottom())
            this.scrollToBottom();
        }, { once: true });
      }
    });
  }
  showNewMessageBar(text) {
    if (!text) {
      this.newMessageCount++;
      text = this.newMessageCount === 1 ? "New message" : `${this.newMessageCount} new messages`;
    }
    const bar = this.element.parentElement?.querySelector("[data-scroll-position-target=newMessageBar]");
    if (bar) {
      bar.classList.remove("hidden");
      const countEl = bar.querySelector("[data-count]");
      if (countEl)
        countEl.textContent = text;
    }
  }
  hideNewMessageBar() {
    this.newMessageCount = 0;
    const bar = this.element.parentElement?.querySelector("[data-scroll-position-target=newMessageBar]");
    if (bar)
      bar.classList.add("hidden");
  }
  getSavedPosition() {
    try {
      const positions = JSON.parse(sessionStorage.getItem("channel_scroll") || "{}");
      return positions[this.channelIdValue] ?? null;
    } catch {
      return null;
    }
  }
  savePosition(pos) {
    if (this._initializing)
      return;
    try {
      const positions = JSON.parse(sessionStorage.getItem("channel_scroll") || "{}");
      positions[this.channelIdValue] = pos;
      sessionStorage.setItem("channel_scroll", JSON.stringify(positions));
      if (this.isNearBottom() && !this.hasNewerValue) {
        this._lastAnchorId = "__bottom__";
        sessionStorage.setItem("channel_anchor_" + this.channelIdValue, "__bottom__");
      } else {
        const anchor = this._findAnchorMessage();
        if (anchor) {
          this._lastAnchorId = anchor.element.id.replace("message_", "");
          sessionStorage.setItem("channel_anchor_" + this.channelIdValue, this._lastAnchorId);
        }
      }
    } catch {
    }
  }
  getSavedAnchor() {
    try {
      return sessionStorage.getItem("channel_anchor_" + this.channelIdValue) || null;
    } catch {
      return null;
    }
  }
  clearSavedAnchor() {
    try {
      sessionStorage.removeItem("channel_anchor_" + this.channelIdValue);
    } catch {
    }
  }
  async loadAroundMessage(messageId) {
    const serverId = this.serverIdValue;
    const channelId = this.channelIdValue;
    const url = `/servers/${serverId}/channels/${channelId}/around_messages?around=${messageId}`;
    try {
      const response = await fetch(url, {
        headers: {
          Accept: "text/html",
          "X-Requested-With": "XMLHttpRequest"
        }
      });
      if (!response.ok) {
        this.clearSavedAnchor();
        this.scrollToBottom();
        this._initializing = false;
        return;
      }
      const html = await response.text();
      if (!html.trim()) {
        this.clearSavedAnchor();
        this.scrollToBottom();
        this._initializing = false;
        return;
      }
      this._suppressObserver = true;
      this.element.innerHTML = html;
      this.hasOlderValue = response.headers.get("X-Has-Older") !== "false";
      this.hasNewerValue = response.headers.get("X-Has-Newer") !== "false";
      const allMessages = this._getMessageElements();
      if (allMessages.length > 0) {
        this.oldestMessageIdValue = allMessages[0].id.replace("message_", "");
        this.newestMessageIdValue = allMessages[allMessages.length - 1].id.replace("message_", "");
      }
      const anchorEl = document.getElementById(`message_${messageId}`);
      if (anchorEl) {
        anchorEl.scrollIntoView({ block: "center" });
      }
      const images = Array.from(this.element.querySelectorAll("img")).filter((i) => !i.complete);
      if (images.length > 0) {
        let loaded = 0;
        let settled = false;
        const settle = () => {
          if (settled)
            return;
          if (++loaded >= images.length) {
            settled = true;
            if (anchorEl && anchorEl.isConnected) {
              anchorEl.scrollIntoView({ block: "center" });
            }
            this._suppressObserver = false;
            this._initializing = false;
          }
        };
        images.forEach((i) => i.addEventListener("load", settle, { once: true }));
        images.forEach((i) => i.addEventListener("error", settle, { once: true }));
        setTimeout(() => {
          if (!settled) {
            settled = true;
            if (anchorEl && anchorEl.isConnected) {
              anchorEl.scrollIntoView({ block: "center" });
            }
            this._suppressObserver = false;
            this._initializing = false;
          }
        }, 3000);
      } else {
        this._suppressObserver = false;
        this._initializing = false;
      }
    } catch (e) {
      console.error("Failed to load around message:", e);
      this._suppressObserver = false;
      this.clearSavedAnchor();
      this.scrollToBottom();
      this._initializing = false;
    }
  }
}

// app/javascript/controllers/toast_controller.js
class toast_controller_default extends Controller {
  connect() {
    setTimeout(() => {
      this.element.style.transition = "opacity 0.3s";
      this.element.style.opacity = "0";
      setTimeout(() => this.element.remove(), 300);
    }, 4000);
  }
}

// app/javascript/controllers/unified_picker_controller.js
var EMOJI_CATEGORIES = {
  Smileys: ["\uD83D\uDE00", "\uD83D\uDE03", "\uD83D\uDE04", "\uD83D\uDE01", "\uD83D\uDE06", "\uD83D\uDE05", "\uD83E\uDD23", "\uD83D\uDE02", "\uD83D\uDE42", "\uD83D\uDE43", "\uD83D\uDE09", "\uD83D\uDE0A", "\uD83D\uDE07", "\uD83E\uDD70", "\uD83D\uDE0D", "\uD83E\uDD29", "\uD83D\uDE18", "\uD83D\uDE17", "\uD83D\uDE1A", "\uD83D\uDE19", "\uD83E\uDD72", "\uD83D\uDE0B", "\uD83D\uDE1B", "\uD83D\uDE1C", "\uD83E\uDD2A", "\uD83D\uDE1D", "\uD83E\uDD11", "\uD83E\uDD17", "\uD83E\uDD2D", "\uD83E\uDD2B", "\uD83E\uDD14", "\uD83E\uDEE1", "\uD83E\uDD10", "\uD83E\uDD28", "\uD83D\uDE10", "\uD83D\uDE11", "\uD83D\uDE36", "\uD83E\uDEE5", "\uD83D\uDE0F", "\uD83D\uDE12", "\uD83D\uDE44", "\uD83D\uDE2C", "\uD83E\uDD25", "\uD83D\uDE0C", "\uD83D\uDE14", "\uD83D\uDE2A", "\uD83E\uDD24", "\uD83D\uDE34", "\uD83D\uDE37", "\uD83E\uDD12", "\uD83E\uDD15", "\uD83E\uDD22", "\uD83E\uDD2E", "\uD83E\uDD75", "\uD83E\uDD76", "\uD83E\uDD74", "\uD83D\uDE35", "\uD83E\uDD2F", "\uD83E\uDD20", "\uD83E\uDD73", "\uD83E\uDD78", "\uD83D\uDE0E", "\uD83E\uDD13", "\uD83E\uDDD0", "\uD83D\uDE21", "\uD83D\uDE20", "\uD83E\uDD2C", "\uD83D\uDE08", "\uD83D\uDC7F", "\uD83D\uDC80", "\uD83D\uDCA9", "\uD83E\uDD21", "\uD83D\uDC7B", "\uD83D\uDC7D", "\uD83E\uDD16"],
  Gestures: ["\uD83D\uDC4D", "\uD83D\uDC4E", "\uD83D\uDC4A", "✊", "\uD83E\uDD1B", "\uD83E\uDD1C", "\uD83D\uDC4F", "\uD83D\uDE4C", "\uD83D\uDC50", "\uD83E\uDD32", "\uD83E\uDD1D", "\uD83D\uDE4F", "✌️", "\uD83E\uDD1E", "\uD83E\uDD1F", "\uD83E\uDD18", "\uD83D\uDC4C", "\uD83E\uDD0C", "\uD83E\uDD0F", "\uD83D\uDC48", "\uD83D\uDC49", "\uD83D\uDC46", "\uD83D\uDC47", "☝️", "✋", "\uD83E\uDD1A", "\uD83D\uDD90️", "\uD83D\uDD96", "\uD83D\uDC4B", "\uD83E\uDD19", "\uD83D\uDCAA", "\uD83E\uDDBE", "\uD83D\uDD95"],
  Hearts: ["❤️", "\uD83E\uDDE1", "\uD83D\uDC9B", "\uD83D\uDC9A", "\uD83D\uDC99", "\uD83D\uDC9C", "\uD83D\uDDA4", "\uD83E\uDD0D", "\uD83E\uDD0E", "\uD83D\uDC94", "❤️‍\uD83D\uDD25", "❤️‍\uD83E\uDE79", "\uD83D\uDC95", "\uD83D\uDC9E", "\uD83D\uDC93", "\uD83D\uDC97", "\uD83D\uDC96", "\uD83D\uDC98", "\uD83D\uDC9D", "\uD83D\uDC9F"],
  Objects: ["\uD83D\uDD25", "⭐", "\uD83C\uDF1F", "✨", "\uD83D\uDCAB", "\uD83C\uDF89", "\uD83C\uDF8A", "\uD83C\uDF88", "\uD83C\uDF81", "\uD83C\uDFC6", "\uD83E\uDD47", "\uD83C\uDFAE", "\uD83C\uDFAF", "\uD83C\uDFB2", "\uD83D\uDD2E", "\uD83D\uDC8E", "\uD83D\uDCB0", "\uD83D\uDCA1", "\uD83D\uDCCC", "\uD83D\uDCCE", "✏️", "\uD83D\uDCDD", "\uD83D\uDCBB", "⌨️", "\uD83D\uDDA5️", "\uD83D\uDCF1", "☎️", "\uD83D\uDCF7", "\uD83C\uDFB5", "\uD83C\uDFB6", "\uD83C\uDFB8", "\uD83C\uDFB9", "\uD83C\uDF55", "\uD83C\uDF54", "\uD83C\uDF7A", "\uD83C\uDF77", "☕"]
};
var FREQUENTLY_USED_KEY = "unified_picker_frequently_used";
var LAST_TAB_KEY = "unified_picker_last_tab";
var MAX_FREQUENT = 24;

class unified_picker_controller_default extends Controller {
  static targets = ["panel", "input", "content", "searchInput", "tabGifs", "tabStickers", "tabEmoji"];
  static values = {
    serverId: String,
    canSendGifs: { type: Boolean, default: true },
    canSendCustomEmojis: { type: Boolean, default: true },
    canSendCustomStickers: { type: Boolean, default: true },
    serverName: String,
    userServers: String
  };
  connect() {
    this.activeTab = localStorage.getItem(LAST_TAB_KEY) || "emoji";
    this.searchQuery = "";
    this.tenorPos = "";
    this.tenorLoading = false;
    this.serverEmojisCache = {};
    this.serverStickersCache = {};
    this.userCollections = [];
    this.userFavoriteIds = new Set;
    this.collapsedSections = JSON.parse(localStorage.getItem("picker_collapsed") || "{}");
    this.frequentlyUsed = JSON.parse(localStorage.getItem(FREQUENTLY_USED_KEY) || "[]");
    this.gifSubView = null;
    this.currentCollectionFavorites = null;
    this.boundClose = this.closeOnClickOutside.bind(this);
    document.addEventListener("mousedown", this.boundClose);
    this.debounceTimer = null;
    this.boundDismissCtxOnClick = (e) => {
      const menu = document.getElementById("gif-context-menu");
      if (!menu || !menu.contains(e.target))
        this.dismissContextMenu();
    };
    this.boundDismissCtxOnKey = (e) => {
      if (e.key === "Escape")
        this.dismissContextMenu();
    };
    this.boundDismissCtxOnScroll = () => this.dismissContextMenu();
    this.boundOnFavoritesChanged = (e) => {
      if (e.detail.source === "picker")
        return;
      const { gifId, favorited } = e.detail;
      if (favorited) {
        this.userFavoriteIds.add(gifId);
      } else {
        this.userFavoriteIds.delete(gifId);
      }
      this.currentCollectionFavorites = null;
      this._cachedCollectionId = null;
      if (this.activeTab === "gifs" && this.gifSubView && this.gifSubView !== "_trending" && !this.panelTarget.classList.contains("hidden")) {
        this.loadCollectionGifs(this.gifSubView, this.searchQuery);
      }
    };
    document.addEventListener("gif-favorites-changed", this.boundOnFavoritesChanged);
    this._eagerLoadEmojiMap();
  }
  async _eagerLoadEmojiMap() {
    if (window._emojiMap && Object.keys(window._emojiMap).length > 0)
      return;
    const serverIds = [];
    if (this.hasServerIdValue && this.serverIdValue) {
      serverIds.push(this.serverIdValue);
    }
    if (this.hasUserServersValue && this.userServersValue) {
      try {
        const servers = JSON.parse(this.userServersValue);
        servers.forEach((s) => {
          if (!serverIds.includes(String(s.id)))
            serverIds.push(String(s.id));
        });
      } catch (e) {
      }
    }
    for (const serverId of serverIds) {
      await this.fetchServerEmojis(serverId);
    }
    document.dispatchEvent(new CustomEvent("inferno:emoji-map-ready"));
  }
  disconnect() {
    document.removeEventListener("mousedown", this.boundClose);
    document.removeEventListener("gif-favorites-changed", this.boundOnFavoritesChanged);
    if (this.debounceTimer)
      clearTimeout(this.debounceTimer);
    this.dismissContextMenu();
  }
  toggle() {
    const panel = this.panelTarget;
    const wasHidden = panel.classList.contains("hidden");
    panel.classList.toggle("hidden");
    if (wasHidden) {
      this.updateTabStyles();
      this.renderCurrentTab();
      if (this.hasSearchInputTarget)
        this.searchInputTarget.focus();
    }
  }
  close() {
    this.panelTarget.classList.add("hidden");
  }
  closeOnClickOutside(event) {
    if (this.panelTarget.contains(event.target))
      return;
    const toggleBtn = this.panelTarget.parentElement;
    if (toggleBtn && toggleBtn.contains(event.target))
      return;
    const ctxMenu = document.getElementById("gif-context-menu");
    if (ctxMenu && ctxMenu.contains(event.target))
      return;
    if (!this.panelTarget.classList.contains("hidden")) {
      this.close();
    }
  }
  switchTab(event) {
    const tab = event.currentTarget.dataset.tab;
    if (this.activeTab === tab)
      return;
    this.activeTab = tab;
    localStorage.setItem(LAST_TAB_KEY, tab);
    this.searchQuery = "";
    this.tenorPos = "";
    this.gifSubView = null;
    this.currentCollectionFavorites = null;
    if (this.hasSearchInputTarget)
      this.searchInputTarget.value = "";
    this.updateTabStyles();
    this.renderCurrentTab();
  }
  updateTabStyles() {
    const tabs = { gifs: this.tabGifsTarget, stickers: this.tabStickersTarget, emoji: this.tabEmojiTarget };
    Object.entries(tabs).forEach(([name, el]) => {
      if (name === this.activeTab) {
        el.classList.add("text-white", "border-orange-500");
        el.classList.remove("text-gray-400", "border-transparent");
      } else {
        el.classList.remove("text-white", "border-orange-500");
        el.classList.add("text-gray-400", "border-transparent");
      }
    });
  }
  onSearch(event) {
    const query = event.target.value.trim();
    if (this.debounceTimer)
      clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => {
      this.searchQuery = query;
      this.tenorPos = "";
      this.renderCurrentTab();
    }, this.activeTab === "gifs" ? 400 : 150);
  }
  clearSearch() {
    this.searchQuery = "";
    if (this.hasSearchInputTarget)
      this.searchInputTarget.value = "";
  }
  renderCurrentTab() {
    switch (this.activeTab) {
      case "gifs":
        this.renderGifsTab();
        break;
      case "stickers":
        this.renderStickersTab();
        break;
      case "emoji":
        this.renderEmojiTab();
        break;
    }
  }
  async renderGifsTab() {
    const content = this.contentTarget;
    if (!this.canSendGifsValue) {
      content.innerHTML = `<div class="flex items-center justify-center h-32 text-gray-500 text-sm">You don't have permission to send GIFs</div>`;
      return;
    }
    await this.loadUserFavoriteIds();
    if (this.gifSubView) {
      if (this.gifSubView === "_trending") {
        if (this.searchQuery) {
          this.showLoading();
          await this.searchTenor(this.searchQuery);
        } else {
          this.showLoading();
          await this.loadTrending();
        }
      } else {
        await this.loadCollectionGifs(this.gifSubView, this.searchQuery);
      }
      return;
    }
    if (this.searchQuery) {
      this.showLoading();
      await this.searchTenor(this.searchQuery);
    } else {
      await this.renderGifHome();
    }
  }
  showLoading() {
    this.contentTarget.innerHTML = `<div class="flex items-center justify-center h-32 text-gray-500 text-sm"><svg class="w-5 h-5 animate-spin mr-2" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/></svg>Loading...</div>`;
  }
  async renderGifHome() {
    const content = this.contentTarget;
    try {
      const resp = await fetch("/api/gif_collections");
      if (resp.ok) {
        const data = await resp.json();
        this.userCollections = data.collections;
      }
    } catch (e) {
    }
    let html = `<div class="grid grid-cols-2 gap-2 p-1">`;
    const favCollection = this.userCollections.find((c) => c.name === "Favorites");
    html += this.collectionTile("Favorites", favCollection?.favorites_count || 0, favCollection?.id || "default", "\uD83D\uDD25");
    html += this.collectionTile("Trending GIFs", "", "_trending", "\uD83D\uDCC8");
    this.userCollections.filter((c) => c.name !== "Favorites").forEach((c) => {
      html += this.collectionTile(c.name, c.favorites_count, c.id, c.icon || "\uD83D\uDCC1", true);
    });
    html += `</div>`;
    content.innerHTML = html;
  }
  collectionTile(name, count, id, icon, deletable = false) {
    const actions = deletable ? "click->unified-picker#openCollection contextmenu->unified-picker#showCollectionContextMenu" : "click->unified-picker#openCollection";
    const iconHtml = icon && (icon.startsWith("http") || icon.startsWith("/")) ? `<img src="${this.escapeAttr(icon)}" class="w-7 h-7 object-contain mb-1" loading="lazy">` : `<span class="text-2xl mb-1">${icon}</span>`;
    return `<button type="button" class="flex flex-col items-center justify-center bg-gray-700 hover:bg-gray-600 rounded-lg p-3 cursor-pointer transition text-center" data-action="${actions}" data-collection-id="${id}" data-collection-name="${this.escapeAttr(name)}">
      ${iconHtml}
      <span class="text-white text-xs font-medium truncate w-full">${this.escapeHtml(name)}</span>
      ${count !== "" ? `<span class="text-gray-400 text-xs">${count}</span>` : ""}
    </button>`;
  }
  async openCollection(event) {
    const id = event.currentTarget.dataset.collectionId;
    this.gifSubView = id;
    this.clearSearch();
    this.showLoading();
    if (id === "_trending") {
      await this.loadTrending();
    } else {
      await this.loadCollectionGifs(id);
    }
  }
  goBackToGifHome() {
    this.gifSubView = null;
    this.currentCollectionFavorites = null;
    this.tenorPos = "";
    this.clearSearch();
    this.renderGifHome();
  }
  async loadTrending() {
    try {
      const resp = await fetch(`/api/tenor/trending?pos=${this.tenorPos}`);
      if (!resp.ok)
        throw new Error;
      const data = await resp.json();
      this.renderGifGrid(data.results, data.next, true);
    } catch (e) {
      this.contentTarget.innerHTML = `<div class="text-center text-gray-500 text-sm py-8">Failed to load trending GIFs</div>`;
    }
  }
  async loadCollectionGifs(collectionId, filterQuery) {
    if (!this.currentCollectionFavorites || this._cachedCollectionId !== collectionId) {
      const url = collectionId === "default" ? "/api/gif_favorites" : `/api/gif_favorites?collection_id=${collectionId}`;
      try {
        const resp = await fetch(url);
        if (!resp.ok)
          throw new Error;
        const data = await resp.json();
        this.currentCollectionFavorites = data.favorites.map((f) => ({
          id: f.tenor_gif_id,
          favoriteId: f.id,
          url: f.tenor_url,
          preview_url: f.preview_url,
          gif_url: f.gif_url,
          description: f.description || ""
        }));
        this._cachedCollectionId = collectionId;
      } catch (e) {
        this.contentTarget.innerHTML = `<div class="text-center text-gray-500 text-sm py-8">Failed to load favorites</div>`;
        return;
      }
    }
    let results = this.currentCollectionFavorites;
    if (filterQuery) {
      const q = filterQuery.toLowerCase();
      results = results.filter((f) => f.description.toLowerCase().includes(q) || f.url.toLowerCase().includes(q));
    }
    this.renderGifGrid(results, "", true);
  }
  async searchTenor(query) {
    if (this.tenorLoading)
      return;
    this.tenorLoading = true;
    try {
      const resp = await fetch(`/api/tenor/search?q=${encodeURIComponent(query)}&pos=${this.tenorPos}`);
      if (!resp.ok)
        throw new Error;
      const data = await resp.json();
      this.renderGifGrid(data.results, data.next, !this.tenorPos);
      this.tenorLoading = false;
    } catch (e) {
      this.contentTarget.innerHTML = `<div class="text-center text-gray-500 text-sm py-8">Failed to search GIFs</div>`;
      this.tenorLoading = false;
    }
  }
  renderGifGrid(results, nextPos, replace = false) {
    const content = this.contentTarget;
    let backBtn = `<button type="button" class="flex items-center gap-1 text-gray-400 hover:text-white text-xs mb-2 px-1 cursor-pointer" data-action="click->unified-picker#goBackToGifHome"><svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg> Back</button>`;
    let html = results.map((gif) => {
      const previewUrl = gif.preview_url || gif.gif_url;
      const favAttr = gif.favoriteId ? ` data-favorite-id="${this.escapeAttr(gif.favoriteId)}"` : "";
      const actions = gif.favoriteId ? "click->unified-picker#selectGif contextmenu->unified-picker#showContextMenu" : "click->unified-picker#selectGif";
      const isFav = this.userFavoriteIds.has(gif.id);
      const iconClass = isFav ? "text-orange-500" : "text-white/80";
      const fillAttr = isFav ? 'fill="currentColor"' : 'fill="none" stroke="currentColor" stroke-width="2"';
      const saveBtn = `<button type="button" class="gif-picker-save absolute top-1 left-1 z-10 w-6 h-6 rounded-full bg-black/60 hover:bg-black/80 flex items-center justify-center cursor-pointer" data-action="click->unified-picker#togglePickerFavorite:stop:prevent" data-tenor-gif-id="${this.escapeAttr(gif.id)}"><svg class="w-3.5 h-3.5 ${iconClass}" ${fillAttr} viewBox="0 0 24 24"><path ${isFav ? "" : 'stroke-linecap="round" stroke-linejoin="round" '}d="M12 23c-4.97 0-9-2.69-9-6 0-2.4 1.68-4.47 2.64-5.27.32-.27.8-.04.8.39v.51c0 1.28.49 2.52 1.38 3.46.09.1.25.1.34 0 .37-.4.65-.87.82-1.39.09-.27.42-.37.63-.18C11.4 16.18 12.5 17.88 12.5 20c0 .28.22.5.5.5s.5-.22.5-.5c0-2.98-1.63-5.58-4.07-6.97a.249.249 0 01-.01-.43C11.26 11.45 13 9.13 13 6.5c0-.99-.16-1.94-.47-2.83a.252.252 0 01.34-.31C16.68 5.38 21 9.49 21 14c0 5.38-4.03 9-9 9z"/></svg></button>`;
      return `<div class="gif-grid-item relative cursor-pointer rounded overflow-hidden hover:ring-2 hover:ring-orange-500 transition" data-action="${actions}" data-gif-url="${this.escapeAttr(gif.url)}" data-tenor-gif-id="${this.escapeAttr(gif.id)}"${favAttr} data-preview-url="${this.escapeAttr(gif.preview_url || "")}" data-full-gif-url="${this.escapeAttr(gif.gif_url || "")}"><img src="${this.escapeAttr(previewUrl)}" alt="${this.escapeAttr(gif.description || "GIF")}" class="w-full h-auto" loading="lazy">${saveBtn}</div>`;
    }).join("");
    if (results.length === 0) {
      html = `<div class="text-center text-gray-500 text-sm py-8">No GIFs found</div>`;
    }
    if (replace) {
      const showBack = this.gifSubView || this.searchQuery;
      content.innerHTML = (showBack ? backBtn : "") + `<div class="grid grid-cols-2 gap-1 p-1">${html}</div>`;
    } else {
      const grid = content.querySelector(".grid");
      if (grid)
        grid.insertAdjacentHTML("beforeend", html);
    }
    if (nextPos && results.length > 0) {
      this.tenorPos = nextPos;
      const loadMore = document.createElement("button");
      loadMore.type = "button";
      loadMore.className = "w-full py-2 text-center text-gray-400 hover:text-white text-xs cursor-pointer";
      loadMore.textContent = "Load more...";
      loadMore.addEventListener("click", () => {
        loadMore.remove();
        if (this.searchQuery) {
          this.searchTenor(this.searchQuery);
        } else {
          this.loadTrending();
        }
      });
      content.appendChild(loadMore);
    }
  }
  selectGif(event) {
    const el = event.currentTarget;
    const gifUrl = el.dataset.gifUrl;
    if (!gifUrl)
      return;
    const input = this.inputTarget;
    input.value = gifUrl;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    const form = input.closest("form");
    if (form)
      form.requestSubmit();
    this.close();
  }
  async togglePickerFavorite(event) {
    const btn = event.currentTarget;
    const gifId = btn.dataset.tenorGifId;
    if (!gifId)
      return;
    const gifEl = btn.closest(".gif-grid-item");
    const tenorUrl = gifEl?.dataset.gifUrl || "";
    const gifUrl = gifEl?.dataset.fullGifUrl || "";
    const previewUrl = gifEl?.dataset.previewUrl || "";
    try {
      const resp = await fetch("/api/gif_favorites/toggle", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({
          tenor_gif_id: gifId,
          tenor_url: tenorUrl,
          gif_url: gifUrl,
          preview_url: previewUrl,
          description: ""
        })
      });
      if (!resp.ok)
        throw new Error;
      const data = await resp.json();
      if (data.favorited) {
        this.userFavoriteIds.add(gifId);
      } else {
        this.userFavoriteIds.delete(gifId);
      }
      const isFav = data.favorited;
      const iconClass = isFav ? "text-orange-500" : "text-white/80";
      const fillAttr = isFav ? 'fill="currentColor"' : 'fill="none" stroke="currentColor" stroke-width="2"';
      btn.innerHTML = `<svg class="w-3.5 h-3.5 ${iconClass}" ${fillAttr} viewBox="0 0 24 24"><path ${isFav ? "" : 'stroke-linecap="round" stroke-linejoin="round" '}d="M12 23c-4.97 0-9-2.69-9-6 0-2.4 1.68-4.47 2.64-5.27.32-.27.8-.04.8.39v.51c0 1.28.49 2.52 1.38 3.46.09.1.25.1.34 0 .37-.4.65-.87.82-1.39.09-.27.42-.37.63-.18C11.4 16.18 12.5 17.88 12.5 20c0 .28.22.5.5.5s.5-.22.5-.5c0-2.98-1.63-5.58-4.07-6.97a.249.249 0 01-.01-.43C11.26 11.45 13 9.13 13 6.5c0-.99-.16-1.94-.47-2.83a.252.252 0 01.34-.31C16.68 5.38 21 9.49 21 14c0 5.38-4.03 9-9 9z"/></svg>`;
      this.currentCollectionFavorites = null;
      this._cachedCollectionId = null;
      document.dispatchEvent(new CustomEvent("gif-favorites-changed", { detail: { gifId, favorited: data.favorited, source: "picker" } }));
      if (!data.favorited) {
        const isDefaultFavorites = this.gifSubView === "default" || this.userCollections.find((c) => c.id === this.gifSubView)?.name === "Favorites";
        if (isDefaultFavorites)
          this.renderCurrentTab();
      }
    } catch (e) {
      console.error("Failed to toggle favorite:", e);
    }
  }
  async renderStickersTab() {
    const content = this.contentTarget;
    if (!this.canSendGifsValue || !this.canSendCustomStickersValue) {
      content.innerHTML = `<div class="flex items-center justify-center h-32 text-gray-500 text-sm">You don't have permission to send stickers</div>`;
      return;
    }
    const servers = this.getUserServers();
    let html = "";
    for (const server of servers) {
      const stickers = await this.fetchServerStickers(server.id);
      const filtered = this.searchQuery ? stickers.filter((s) => s.name.toLowerCase().includes(this.searchQuery.toLowerCase())) : stickers;
      if (filtered.length === 0 && this.searchQuery)
        continue;
      const collapsed = this.collapsedSections[`sticker_${server.id}`];
      html += this.collapsibleSection(`sticker_${server.id}`, this.escapeHtml(server.name), collapsed, () => {
        if (filtered.length === 0)
          return `<div class="text-gray-500 text-xs px-2 py-1">No stickers yet</div>`;
        return `<div class="grid grid-cols-3 gap-1">${filtered.map((s) => `<div class="cursor-pointer rounded-lg overflow-hidden hover:ring-2 hover:ring-orange-500 transition p-1 bg-gray-700" data-action="click->unified-picker#selectSticker" data-sticker-url="${this.escapeAttr(s.image_url)}" data-sticker-name="${this.escapeAttr(s.name)}" title="${this.escapeAttr(s.name)}"><img src="${this.escapeAttr(s.image_url)}" alt="${this.escapeAttr(s.name)}" class="w-full h-auto" loading="lazy"></div>`).join("")}</div>`;
      });
    }
    if (!html) {
      html = `<div class="text-center text-gray-500 text-sm py-8">No stickers available</div>`;
    }
    content.innerHTML = html;
  }
  selectSticker(event) {
    const el = event.currentTarget;
    const url = el.dataset.stickerUrl;
    if (!url)
      return;
    const input = this.inputTarget;
    input.value = url;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    const form = input.closest("form");
    if (form)
      form.requestSubmit();
    this.close();
  }
  async renderEmojiTab() {
    const content = this.contentTarget;
    let html = "";
    if (this.frequentlyUsed.length > 0 && !this.searchQuery) {
      const collapsed = this.collapsedSections["freq_emoji"];
      html += this.collapsibleSection("freq_emoji", "\uD83D\uDD50 Frequently Used", collapsed, () => {
        return `<div class="flex flex-wrap gap-0.5">${this.frequentlyUsed.map((e) => {
          if (e.type === "custom") {
            return `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center hover:bg-gray-700 rounded cursor-pointer" data-action="click->unified-picker#selectCustomEmoji" data-emoji-name="${this.escapeAttr(e.name)}" data-emoji-url="${this.escapeAttr(e.url || "")}" title=":${this.escapeAttr(e.name)}:"><img src="${this.escapeAttr(e.url)}" class="w-6 h-6 object-contain" loading="lazy"></button>`;
          }
          return `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center text-xl hover:bg-gray-700 rounded cursor-pointer" data-action="click->unified-picker#selectEmoji" data-emoji="${e.emoji}">${e.emoji}</button>`;
        }).join("")}</div>`;
      });
    }
    if (this.canSendCustomEmojisValue) {
      const servers = this.getUserServers();
      for (const server of servers) {
        const emojis = await this.fetchServerEmojis(server.id);
        const filtered = this.searchQuery ? emojis.filter((e) => e.name.toLowerCase().includes(this.searchQuery.toLowerCase())) : emojis;
        if (filtered.length === 0)
          continue;
        const collapsed = this.collapsedSections[`emoji_${server.id}`];
        html += this.collapsibleSection(`emoji_${server.id}`, this.escapeHtml(server.name), collapsed, () => {
          return `<div class="flex flex-wrap gap-0.5">${filtered.map((e) => `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center hover:bg-gray-700 rounded cursor-pointer" data-action="click->unified-picker#selectCustomEmoji" data-emoji-name="${this.escapeAttr(e.name)}" data-emoji-url="${this.escapeAttr(e.image_url)}" title=":${this.escapeAttr(e.name)}:"><img src="${this.escapeAttr(e.image_url)}" class="w-6 h-6 object-contain" loading="lazy"></button>`).join("")}</div>`;
        });
      }
    }
    Object.entries(EMOJI_CATEGORIES).forEach(([category, emojis]) => {
      const filtered = this.searchQuery ? emojis.filter((e) => e.includes(this.searchQuery)) : emojis;
      if (filtered.length === 0 && this.searchQuery)
        return;
      const collapsed = this.collapsedSections[`cat_${category}`];
      html += this.collapsibleSection(`cat_${category}`, category, collapsed, () => {
        return `<div class="flex flex-wrap gap-0.5">${filtered.map((emoji) => `<button type="button" class="w-9 h-9 sm:w-8 sm:h-8 flex items-center justify-center text-xl hover:bg-gray-700 rounded cursor-pointer" data-action="click->unified-picker#selectEmoji" data-emoji="${emoji}">${emoji}</button>`).join("")}</div>`;
      });
    });
    if (!html) {
      html = `<div class="text-center text-gray-500 text-sm py-8">No matches found</div>`;
    }
    content.innerHTML = html;
  }
  selectEmoji(event) {
    const emoji = event.currentTarget.dataset.emoji;
    this.trackFrequentlyUsed({ type: "standard", emoji });
    const input = this.inputTarget;
    const start2 = input.selectionStart;
    const end = input.selectionEnd;
    input.value = input.value.substring(0, start2) + emoji + input.value.substring(end);
    input.selectionStart = input.selectionEnd = start2 + emoji.length;
    input.focus();
    input.dispatchEvent(new Event("input", { bubbles: true }));
    this.close();
  }
  selectCustomEmoji(event) {
    const name = event.currentTarget.dataset.emojiName;
    const url = event.currentTarget.dataset.emojiUrl;
    this.trackFrequentlyUsed({ type: "custom", name, url });
    const input = this.inputTarget;
    const text = `:${name}:`;
    const start2 = input.selectionStart;
    const end = input.selectionEnd;
    input.value = input.value.substring(0, start2) + text + input.value.substring(end);
    input.selectionStart = input.selectionEnd = start2 + text.length;
    input.focus();
    input.dispatchEvent(new Event("input", { bubbles: true }));
    this.close();
  }
  collapsibleSection(key, title, collapsed, contentFn) {
    const chevron = collapsed ? `<svg class="w-3 h-3 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/></svg>` : `<svg class="w-3 h-3 transition-transform" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>`;
    return `<div class="mb-2">
      <button type="button" class="flex items-center gap-1 w-full px-1 py-1 text-xs font-semibold text-gray-400 uppercase hover:text-gray-200 cursor-pointer" data-action="click->unified-picker#toggleSection" data-section-key="${key}">
        ${chevron}
        <span>${title}</span>
      </button>
      <div class="${collapsed ? "hidden" : ""}" data-section-content="${key}">
        ${collapsed ? "" : contentFn()}
      </div>
    </div>`;
  }
  toggleSection(event) {
    const key = event.currentTarget.dataset.sectionKey;
    this.collapsedSections[key] = !this.collapsedSections[key];
    localStorage.setItem("picker_collapsed", JSON.stringify(this.collapsedSections));
    this.renderCurrentTab();
  }
  trackFrequentlyUsed(entry) {
    this.frequentlyUsed = this.frequentlyUsed.filter((e) => {
      if (entry.type === "standard")
        return e.emoji !== entry.emoji;
      return e.name !== entry.name;
    });
    this.frequentlyUsed.unshift(entry);
    this.frequentlyUsed = this.frequentlyUsed.slice(0, MAX_FREQUENT);
    localStorage.setItem(FREQUENTLY_USED_KEY, JSON.stringify(this.frequentlyUsed));
  }
  getUserServers() {
    try {
      return JSON.parse(this.userServersValue || "[]");
    } catch (e) {
      return [];
    }
  }
  async fetchServerEmojis(serverId) {
    if (this.serverEmojisCache[serverId])
      return this.serverEmojisCache[serverId];
    try {
      const resp = await fetch(`/servers/${serverId}/emojis`, { headers: { Accept: "application/json" } });
      if (resp.ok) {
        const data = await resp.json();
        this.serverEmojisCache[serverId] = data.emojis;
        if (!window._emojiMap)
          window._emojiMap = {};
        if (!window._emojiPUA) {
          window._emojiPUA = {};
          window._emojiReverse = {};
          window._nextPUA = 57344;
        }
        data.emojis.forEach((e) => {
          window._emojiMap[e.name] = e.image_url;
          if (!window._emojiPUA[e.name]) {
            const ch = String.fromCodePoint(window._nextPUA++);
            window._emojiPUA[e.name] = ch;
            window._emojiReverse[ch] = e.name;
          }
        });
        try {
          localStorage.setItem("_emojiMap", JSON.stringify(window._emojiMap));
          localStorage.setItem("_emojiPUA", JSON.stringify(window._emojiPUA));
          localStorage.setItem("_emojiReverse", JSON.stringify(window._emojiReverse));
          localStorage.setItem("_nextPUA", String(window._nextPUA));
        } catch (e) {
        }
        return data.emojis;
      }
    } catch (e) {
    }
    return [];
  }
  async fetchServerStickers(serverId) {
    if (this.serverStickersCache[serverId])
      return this.serverStickersCache[serverId];
    try {
      const resp = await fetch(`/servers/${serverId}/stickers`, { headers: { Accept: "application/json" } });
      if (resp.ok) {
        const data = await resp.json();
        this.serverStickersCache[serverId] = data.stickers;
        return data.stickers;
      }
    } catch (e) {
    }
    return [];
  }
  async loadUserFavoriteIds() {
    if (this.userFavoriteIds.size > 0)
      return;
    try {
      const resp = await fetch("/api/gif_favorites?default=1");
      if (resp.ok) {
        const data = await resp.json();
        this.userFavoriteIds = new Set(data.favorites.map((f) => f.tenor_gif_id));
      }
    } catch (e) {
    }
  }
  showContextMenu(event) {
    event.preventDefault();
    event.stopPropagation();
    const gifEl = event.currentTarget;
    const favoriteId = gifEl.dataset.favoriteId;
    if (!favoriteId)
      return;
    const gifData = (this.currentCollectionFavorites || []).find((f) => f.favoriteId === favoriteId);
    if (!gifData)
      return;
    this.dismissContextMenu();
    const menu = document.createElement("div");
    menu.id = "gif-context-menu";
    menu.className = "fixed bg-gray-800 border border-gray-600 rounded-lg shadow-xl py-1 z-[9999] min-w-[180px] text-sm";
    menu.style.left = `${event.clientX}px`;
    menu.style.top = `${event.clientY}px`;
    const otherCollections = this.userCollections.filter((c) => {
      if (c.id === this.gifSubView)
        return false;
      if (c.name === "Favorites" && this.userFavoriteIds.has(gifData.id))
        return false;
      return true;
    });
    if (otherCollections.length > 0) {
      const header = document.createElement("div");
      header.className = "px-3 py-1.5 text-gray-400 text-xs uppercase font-semibold";
      header.textContent = "Add to";
      menu.appendChild(header);
      otherCollections.forEach((c) => {
        const item = document.createElement("button");
        item.type = "button";
        item.className = "w-full text-left px-3 py-1.5 text-gray-200 hover:bg-gray-700 cursor-pointer flex items-center gap-2";
        item.innerHTML = `<span>${c.name === "Favorites" ? "\uD83D\uDD25" : "\uD83D\uDCC1"}</span> ${this.escapeHtml(c.name)}`;
        item.addEventListener("click", () => this.addToCollection(gifData, c.id));
        menu.appendChild(item);
      });
    }
    const divider = document.createElement("div");
    divider.className = "border-t border-gray-600 my-1";
    menu.appendChild(divider);
    const newCollBtn = document.createElement("button");
    newCollBtn.type = "button";
    newCollBtn.className = "w-full text-left px-3 py-1.5 text-gray-200 hover:bg-gray-700 cursor-pointer flex items-center gap-2";
    newCollBtn.innerHTML = `<span>➕</span> New Collection...`;
    newCollBtn.addEventListener("click", () => this.showNewCollectionInput(menu, gifData));
    menu.appendChild(newCollBtn);
    const removeBtn = document.createElement("button");
    removeBtn.type = "button";
    removeBtn.className = "w-full text-left px-3 py-1.5 text-red-400 hover:bg-gray-700 cursor-pointer flex items-center gap-2";
    removeBtn.innerHTML = `<span>\uD83D\uDDD1️</span> Remove`;
    removeBtn.addEventListener("click", () => this.removeFromFavorites(favoriteId, gifData.id));
    menu.appendChild(removeBtn);
    document.body.appendChild(menu);
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      menu.style.left = `${window.innerWidth - rect.width - 8}px`;
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = `${window.innerHeight - rect.height - 8}px`;
    }
    setTimeout(() => {
      document.addEventListener("mousedown", this.boundDismissCtxOnClick);
      document.addEventListener("keydown", this.boundDismissCtxOnKey);
      this.contentTarget.addEventListener("scroll", this.boundDismissCtxOnScroll);
    }, 0);
  }
  dismissContextMenu() {
    const menu = document.getElementById("gif-context-menu");
    if (menu)
      menu.remove();
    document.removeEventListener("mousedown", this.boundDismissCtxOnClick);
    document.removeEventListener("keydown", this.boundDismissCtxOnKey);
    if (this.hasContentTarget) {
      this.contentTarget.removeEventListener("scroll", this.boundDismissCtxOnScroll);
    }
  }
  async showNewCollectionInput(menu, gifData) {
    menu.innerHTML = "";
    let selectedIcon = "\uD83D\uDCC1";
    const wrapper = document.createElement("div");
    wrapper.className = "p-2 w-[220px]";
    const row = document.createElement("div");
    row.className = "flex items-center gap-1.5 mb-2";
    const iconBtn = document.createElement("button");
    iconBtn.type = "button";
    iconBtn.className = "w-8 h-8 rounded bg-gray-700 hover:bg-gray-600 flex items-center justify-center text-lg cursor-pointer shrink-0 border border-gray-600";
    iconBtn.innerHTML = selectedIcon;
    row.appendChild(iconBtn);
    const input = document.createElement("input");
    input.type = "text";
    input.className = "flex-1 min-w-0 bg-gray-700 text-white text-sm rounded px-2 py-1.5 outline-none focus:ring-1 focus:ring-orange-500";
    input.placeholder = "Collection name";
    row.appendChild(input);
    wrapper.appendChild(row);
    const gridLabel = document.createElement("div");
    gridLabel.className = "text-gray-400 text-xs mb-1";
    gridLabel.textContent = "Icon";
    wrapper.appendChild(gridLabel);
    const grid = document.createElement("div");
    grid.className = "max-h-[140px] overflow-y-auto rounded bg-gray-900/50 p-1";
    const selectIcon = (icon, html) => {
      selectedIcon = icon;
      iconBtn.innerHTML = html;
    };
    const makeEmojiBtn = (emoji) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "w-7 h-7 flex items-center justify-center hover:bg-gray-600 rounded cursor-pointer text-base";
      btn.textContent = emoji;
      btn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        selectIcon(emoji, emoji);
      });
      return btn;
    };
    const makeCustomBtn = (url, name) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "w-7 h-7 flex items-center justify-center hover:bg-gray-600 rounded cursor-pointer";
      btn.title = `:${name}:`;
      btn.innerHTML = `<img src="${this.escapeAttr(url)}" class="w-5 h-5 object-contain" loading="lazy">`;
      btn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        selectIcon(url, `<img src="${this.escapeAttr(url)}" class="w-5 h-5 object-contain">`);
      });
      return btn;
    };
    const servers = this.getUserServers();
    for (const server of servers) {
      const emojis = await this.fetchServerEmojis(server.id);
      if (emojis.length === 0)
        continue;
      const label = document.createElement("div");
      label.className = "text-gray-500 text-[10px] uppercase font-semibold px-0.5 pt-1 pb-0.5";
      label.textContent = server.name;
      grid.appendChild(label);
      const serverGrid = document.createElement("div");
      serverGrid.className = "flex flex-wrap gap-0.5";
      emojis.forEach((e) => serverGrid.appendChild(makeCustomBtn(e.image_url, e.name)));
      grid.appendChild(serverGrid);
    }
    Object.entries(EMOJI_CATEGORIES).forEach(([category, emojis]) => {
      const label = document.createElement("div");
      label.className = "text-gray-500 text-[10px] uppercase font-semibold px-0.5 pt-1 pb-0.5";
      label.textContent = category;
      grid.appendChild(label);
      const catGrid = document.createElement("div");
      catGrid.className = "flex flex-wrap gap-0.5";
      emojis.forEach((e) => catGrid.appendChild(makeEmojiBtn(e)));
      grid.appendChild(catGrid);
    });
    wrapper.appendChild(grid);
    const submit = async () => {
      const name = input.value.trim();
      if (!name)
        return;
      input.disabled = true;
      await this.createCollectionAndAdd(name, gifData, selectedIcon);
    };
    input.addEventListener("keydown", async (e) => {
      if (e.key === "Enter")
        await submit();
      if (e.key === "Escape")
        this.dismissContextMenu();
    });
    const createBtn = document.createElement("button");
    createBtn.type = "button";
    createBtn.className = "w-full mt-2 py-1.5 bg-orange-600 hover:bg-orange-500 text-white text-xs font-medium rounded cursor-pointer transition";
    createBtn.textContent = "Create";
    createBtn.addEventListener("click", submit);
    wrapper.appendChild(createBtn);
    menu.appendChild(wrapper);
    requestAnimationFrame(() => input.focus());
  }
  async addToCollection(gifData, collectionId) {
    this.dismissContextMenu();
    try {
      const resp = await fetch("/api/gif_favorites", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({ gif_favorite: {
          collection_id: collectionId,
          tenor_gif_id: gifData.id,
          tenor_url: gifData.url,
          preview_url: gifData.preview_url,
          gif_url: gifData.gif_url,
          description: gifData.description
        } })
      });
      if (!resp.ok)
        throw new Error;
    } catch (e) {
      console.error("Failed to add GIF to collection:", e);
    }
  }
  async removeFromFavorites(favoriteId, tenorGifId) {
    this.dismissContextMenu();
    try {
      const resp = await fetch(`/api/gif_favorites/${favoriteId}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": this.csrfToken() }
      });
      if (!resp.ok)
        throw new Error;
      const isDefaultFavorites = this.gifSubView === "default" || this.userCollections.find((c) => c.id === this.gifSubView)?.name === "Favorites";
      if (isDefaultFavorites && tenorGifId) {
        this.userFavoriteIds.delete(tenorGifId);
        document.dispatchEvent(new CustomEvent("gif-favorites-changed", {
          detail: { gifId: tenorGifId, favorited: false, source: "picker" }
        }));
      }
      this.invalidateAndRefresh();
    } catch (e) {
      console.error("Failed to remove GIF:", e);
    }
  }
  async createCollectionAndAdd(name, gifData, icon) {
    this.dismissContextMenu();
    try {
      const createResp = await fetch("/api/gif_collections", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({ gif_collection: { name, icon } })
      });
      if (!createResp.ok)
        throw new Error;
      const { id: newCollectionId } = await createResp.json();
      const addResp = await fetch("/api/gif_favorites", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrfToken() },
        body: JSON.stringify({ gif_favorite: {
          collection_id: newCollectionId,
          tenor_gif_id: gifData.id,
          tenor_url: gifData.url,
          preview_url: gifData.preview_url,
          gif_url: gifData.gif_url,
          description: gifData.description
        } })
      });
      if (!addResp.ok)
        throw new Error;
      this.userCollections.push({ id: newCollectionId, name, icon, favorites_count: 1 });
    } catch (e) {
      console.error("Failed to create collection:", e);
    }
  }
  showCollectionContextMenu(event) {
    event.preventDefault();
    event.stopPropagation();
    const tileEl = event.currentTarget;
    const collectionId = tileEl.dataset.collectionId;
    const collectionName = tileEl.dataset.collectionName;
    if (!collectionId)
      return;
    this.dismissContextMenu();
    const menu = document.createElement("div");
    menu.id = "gif-context-menu";
    menu.className = "fixed bg-gray-800 border border-gray-600 rounded-lg shadow-xl py-1 z-[9999] min-w-[160px] text-sm";
    menu.style.left = `${event.clientX}px`;
    menu.style.top = `${event.clientY}px`;
    const deleteBtn = document.createElement("button");
    deleteBtn.type = "button";
    deleteBtn.className = "w-full text-left px-3 py-1.5 text-red-400 hover:bg-gray-700 cursor-pointer flex items-center gap-2";
    deleteBtn.innerHTML = `<span>\uD83D\uDDD1️</span> Delete Collection`;
    deleteBtn.addEventListener("click", () => this.deleteCollection(collectionId));
    menu.appendChild(deleteBtn);
    document.body.appendChild(menu);
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      menu.style.left = `${window.innerWidth - rect.width - 8}px`;
    }
    if (rect.bottom > window.innerHeight) {
      menu.style.top = `${window.innerHeight - rect.height - 8}px`;
    }
    setTimeout(() => {
      document.addEventListener("mousedown", this.boundDismissCtxOnClick);
      document.addEventListener("keydown", this.boundDismissCtxOnKey);
    }, 0);
  }
  async deleteCollection(collectionId) {
    this.dismissContextMenu();
    try {
      const resp = await fetch(`/api/gif_collections/${collectionId}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": this.csrfToken() }
      });
      if (!resp.ok)
        throw new Error;
      this.userCollections = this.userCollections.filter((c) => c.id !== collectionId);
      this.renderGifHome();
    } catch (e) {
      console.error("Failed to delete collection:", e);
    }
  }
  invalidateAndRefresh() {
    this.currentCollectionFavorites = null;
    this._cachedCollectionId = null;
    this.renderCurrentTab();
  }
  csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]');
    return meta ? meta.content : "";
  }
  escapeHtml(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }
  escapeAttr(str) {
    return (str || "").replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
}

// app/javascript/controllers/gif_save_controller.js
class gif_save_controller_default extends Controller {
  connect() {
    this.loadFavorites();
    this.stampAllButtons();
    this.setupGifVisibility();
    this.observer = new MutationObserver(() => {
      this.stampAllButtons();
      this.observeGifs();
    });
    this.observer.observe(this.element, { childList: true, subtree: true });
    this.boundOnFavoritesChanged = (e) => {
      if (e.detail.source === "message-stream")
        return;
      const { gifId, favorited } = e.detail;
      if (favorited) {
        this.favoritedIds.add(gifId);
      } else {
        this.favoritedIds.delete(gifId);
      }
      this.element.querySelectorAll(`[data-tenor-gif-id="${gifId}"] .gif-save-btn`).forEach((btn) => {
        btn.innerHTML = this.fireIcon(favorited);
      });
    };
    document.addEventListener("gif-favorites-changed", this.boundOnFavoritesChanged);
  }
  disconnect() {
    if (this.observer)
      this.observer.disconnect();
    if (this.gifVisibilityObserver)
      this.gifVisibilityObserver.disconnect();
    document.removeEventListener("gif-favorites-changed", this.boundOnFavoritesChanged);
  }
  setupGifVisibility() {
    this.gifVisibilityObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        const img = entry.target;
        if (entry.isIntersecting) {
          if (img.dataset.gifOrigSrc) {
            img.src = img.dataset.gifOrigSrc;
            delete img.dataset.gifOrigSrc;
          }
        } else {
          if (img.complete && img.src && !img.dataset.gifOrigSrc) {
            img.dataset.gifOrigSrc = img.src;
            const w = img.naturalWidth || img.offsetWidth;
            const h = img.naturalHeight || img.offsetHeight;
            img.src = `data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='${w}' height='${h}'%3E%3Crect width='100%25' height='100%25' fill='%23374151'/%3E%3C/svg%3E`;
          }
        }
      });
    }, { root: this.element, rootMargin: "200px 0px" });
    this.observeGifs();
  }
  observeGifs() {
    this.element.querySelectorAll("[data-tenor-gif-id] img:not([data-gif-observed])").forEach((img) => {
      img.dataset.gifObserved = "1";
      this.gifVisibilityObserver.observe(img);
    });
    this.element.querySelectorAll("[data-animated-gif]:not([data-gif-observed])").forEach((img) => {
      img.dataset.gifObserved = "1";
      this.gifVisibilityObserver.observe(img);
    });
  }
  async loadFavorites() {
    try {
      const resp = await fetch("/api/gif_favorites?default=1");
      if (resp.ok) {
        const data = await resp.json();
        this.favoritedIds = new Set(data.favorites.map((f) => f.tenor_gif_id));
        this.element.querySelectorAll("[data-tenor-gif-id][data-gif-save-attached] .gif-save-btn").forEach((btn) => {
          const gifId = btn.closest("[data-tenor-gif-id]").dataset.tenorGifId;
          btn.innerHTML = this.fireIcon(this.favoritedIds.has(gifId));
        });
      }
    } catch (e) {
      this.favoritedIds = new Set;
    }
  }
  stampAllButtons() {
    this.element.querySelectorAll("[data-tenor-gif-id]:not([data-gif-save-attached])").forEach((gifEl) => {
      gifEl.dataset.gifSaveAttached = "1";
      const btn = document.createElement("button");
      btn.className = "gif-save-btn absolute top-2 left-2 z-10 w-8 h-8 rounded-full bg-black/60 hover:bg-black/80 flex items-center justify-center cursor-pointer";
      btn.type = "button";
      const gifId = gifEl.dataset.tenorGifId;
      const isFav = this.favoritedIds && this.favoritedIds.has(gifId);
      btn.innerHTML = this.fireIcon(isFav);
      btn.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        this.toggleFavorite(gifEl, btn);
      });
      if (getComputedStyle(gifEl).position === "static") {
        gifEl.style.position = "relative";
      }
      gifEl.appendChild(btn);
    });
  }
  async toggleFavorite(gifEl, btn) {
    const gifId = gifEl.dataset.tenorGifId;
    const tenorUrl = gifEl.dataset.tenorUrl || "";
    const gifUrl = gifEl.dataset.gifUrl || "";
    const previewUrl = gifEl.dataset.previewUrl || "";
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    try {
      const resp = await fetch("/api/gif_favorites/toggle", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({
          tenor_gif_id: gifId,
          tenor_url: tenorUrl,
          gif_url: gifUrl,
          preview_url: previewUrl,
          description: ""
        })
      });
      if (resp.ok) {
        const data = await resp.json();
        if (data.favorited) {
          this.favoritedIds.add(gifId);
        } else {
          this.favoritedIds.delete(gifId);
        }
        btn.innerHTML = this.fireIcon(data.favorited);
        document.dispatchEvent(new CustomEvent("gif-favorites-changed", { detail: { gifId, favorited: data.favorited, source: "message-stream" } }));
      }
    } catch (e) {
      console.error("Failed to toggle GIF favorite:", e);
    }
  }
  fireIcon(filled) {
    if (filled) {
      return `<svg class="w-5 h-5 text-orange-500" fill="currentColor" viewBox="0 0 24 24"><path d="M12 23c-4.97 0-9-2.69-9-6 0-2.4 1.68-4.47 2.64-5.27.32-.27.8-.04.8.39v.51c0 1.28.49 2.52 1.38 3.46.09.1.25.1.34 0 .37-.4.65-.87.82-1.39.09-.27.42-.37.63-.18C11.4 16.18 12.5 17.88 12.5 20c0 .28.22.5.5.5s.5-.22.5-.5c0-2.98-1.63-5.58-4.07-6.97a.249.249 0 01-.01-.43C11.26 11.45 13 9.13 13 6.5c0-.99-.16-1.94-.47-2.83a.252.252 0 01.34-.31C16.68 5.38 21 9.49 21 14c0 5.38-4.03 9-9 9z"/></svg>`;
    }
    return `<svg class="w-5 h-5 text-white/80" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M12 23c-4.97 0-9-2.69-9-6 0-2.4 1.68-4.47 2.64-5.27.32-.27.8-.04.8.39v.51c0 1.28.49 2.52 1.38 3.46.09.1.25.1.34 0 .37-.4.65-.87.82-1.39.09-.27.42-.37.63-.18C11.4 16.18 12.5 17.88 12.5 20c0 .28.22.5.5.5s.5-.22.5-.5c0-2.98-1.63-5.58-4.07-6.97a.249.249 0 01-.01-.43C11.26 11.45 13 9.13 13 6.5c0-.99-.16-1.94-.47-2.83a.252.252 0 01.34-.31C16.68 5.38 21 9.49 21 14c0 5.38-4.03 9-9 9z"/></svg>`;
  }
}

// app/javascript/controllers/dropdown_controller.js
class dropdown_controller_default extends Controller {
  static targets = ["menu"];
  toggle() {
    this.menuTarget.classList.toggle("hidden");
  }
  close() {
    this.menuTarget.classList.add("hidden");
  }
  closeOnClickOutside(event) {
    if (!this.element.contains(event.target)) {
      this.close();
    }
  }
  connect() {
    this.boundClose = this.closeOnClickOutside.bind(this);
    document.addEventListener("click", this.boundClose);
  }
  disconnect() {
    document.removeEventListener("click", this.boundClose);
  }
}

// app/javascript/controllers/server_members_controller.js
class server_members_controller_default extends Controller {
  static values = { serverId: String };
  static targets = ["list"];
  connect() {
    this.subscription = createConsumer3().subscriptions.create({ channel: "ServerChannel", server_id: this.serverIdValue }, {
      received: (data) => this.handleMessage(data)
    });
  }
  disconnect() {
    if (this.subscription)
      this.subscription.unsubscribe();
  }
  handleMessage(data) {
    switch (data.type) {
      case "member_join":
        this.addMember(data);
        break;
      case "member_leave":
        this.removeMember(data);
        break;
      case "presence":
        this.updatePresence(data);
        break;
      case "member_update":
        this.updateMember(data);
        break;
      case "roles_updated":
        this.refreshMemberList();
        break;
    }
  }
  addMember(data) {
    if (!this.hasListTarget)
      return;
    const existing = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`);
    if (existing)
      return;
    const temp = document.createElement("div");
    temp.innerHTML = data.html;
    const memberEl = temp.firstElementChild;
    if (!memberEl)
      return;
    const group = memberEl.getAttribute("data-member-group") || "online";
    this.insertMemberInGroup(memberEl, group);
    this.recountAllGroups();
  }
  removeMember(data) {
    if (!this.hasListTarget)
      return;
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`);
    if (el) {
      el.remove();
      this.recountAllGroups();
    }
  }
  updatePresence(data) {
    if (!this.hasListTarget)
      return;
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`);
    if (!el)
      return;
    const dot = el.querySelector(".rounded-full.border-2");
    if (dot) {
      dot.classList.remove("bg-green-500", "bg-yellow-500", "bg-red-500", "bg-gray-500");
      const colorMap = { online: "bg-green-500", idle: "bg-yellow-500", dnd: "bg-red-500", offline: "bg-gray-500" };
      dot.classList.add(colorMap[data.state] || "bg-gray-500");
    }
    const isOffline = data.state === "offline" || data.state === "invisible";
    if (isOffline) {
      el.classList.add("opacity-40");
    } else {
      el.classList.remove("opacity-40");
    }
    let targetGroup;
    if (isOffline) {
      targetGroup = "offline";
      el.setAttribute("data-member-group", "offline");
    } else {
      const roleGroup = el.getAttribute("data-role-group") || "online";
      targetGroup = roleGroup;
      el.setAttribute("data-member-group", roleGroup);
    }
    this.moveMemberToGroup(el, targetGroup);
    this.recountAllGroups();
  }
  updateMember(data) {
    if (!this.hasListTarget)
      return;
    const el = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`);
    if (el && data.html) {
      const temp = document.createElement("div");
      temp.innerHTML = data.html;
      const newEl = temp.firstElementChild;
      if (newEl) {
        const newGroup = newEl.getAttribute("data-member-group") || "online";
        el.outerHTML = data.html;
        const updatedEl = this.listTarget.querySelector(`[data-user-id="${data.user_id}"]`);
        if (updatedEl) {
          this.moveMemberToGroup(updatedEl, newGroup);
        }
        this.recountAllGroups();
      }
    }
    document.querySelectorAll(`[data-author-id="${data.user_id}"]`).forEach((msgEl) => {
      const nameSpan = msgEl.querySelector(".font-medium.hover\\:underline");
      if (nameSpan) {
        if (data.display_name)
          nameSpan.textContent = data.display_name;
        if (data.role_color)
          nameSpan.style.color = data.role_color;
      }
    });
    const currentUserId = document.body.dataset.currentUserId;
    if (String(data.user_id) === String(currentUserId)) {
      const panel = document.querySelector("[style*='1a1b1e']");
      if (panel) {
        const nameEl = panel.querySelector(".text-white.truncate");
        if (nameEl && data.display_name)
          nameEl.textContent = data.display_name;
        const tagEl = panel.querySelector(".text-gray-400.truncate");
        if (tagEl && data.tag)
          tagEl.textContent = data.tag;
      }
    }
  }
  async refreshMemberList() {
    if (!this.hasListTarget)
      return;
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/members`, {
        headers: { Accept: "text/html" }
      });
      if (res.ok) {
        const html = await res.text();
        const temp = document.createElement("div");
        temp.innerHTML = html;
        const newList = temp.querySelector("[data-server-members-target='list']");
        if (newList) {
          this.listTarget.innerHTML = newList.innerHTML;
        }
      }
    } catch (err) {
    }
  }
  getAllGroupHeaders() {
    return Array.from(this.listTarget.querySelectorAll("[data-status-group]"));
  }
  getGroupMembers(header) {
    const members = [];
    let sibling = header.nextElementSibling;
    while (sibling && !sibling.hasAttribute("data-status-group")) {
      if (sibling.hasAttribute("data-user-id"))
        members.push(sibling);
      sibling = sibling.nextElementSibling;
    }
    return members;
  }
  ensureGroupHeader(group) {
    let header = this.listTarget.querySelector(`[data-status-group="${group}"]`);
    if (header)
      return header;
    const h3 = document.createElement("h3");
    h3.className = "text-xs font-semibold uppercase tracking-wide mb-1 mt-4 first:mt-0 px-2";
    h3.setAttribute("data-status-group", group);
    let position = 0;
    if (group === "online") {
      h3.classList.add("text-gray-400");
      h3.textContent = "Online — 0";
      const existingOnline = this.listTarget.querySelector('[data-status-group="online"]');
      position = existingOnline ? parseInt(existingOnline.getAttribute("data-role-position") || "0", 10) : 0;
    } else if (group === "offline") {
      h3.classList.add("text-gray-400");
      h3.textContent = "Offline — 0";
    } else {
      h3.style.color = "#9ca3af";
      h3.textContent = "Role — 0";
    }
    h3.setAttribute("data-role-position", String(position));
    const insertionPoint = this.findInsertionPointForGroup(group, position);
    if (insertionPoint) {
      insertionPoint.before(h3);
    } else {
      this.listTarget.appendChild(h3);
    }
    return h3;
  }
  findInsertionPointForGroup(group, position) {
    const headers = this.getAllGroupHeaders();
    if (group === "offline") {
      return null;
    }
    const pos = position || 0;
    for (const h of headers) {
      const hGroup = h.getAttribute("data-status-group");
      if (hGroup === "offline")
        return h;
      const hPos = parseInt(h.getAttribute("data-role-position") || "0", 10);
      if (hPos < pos)
        return h;
    }
    const offlineHeader = this.listTarget.querySelector('[data-status-group="offline"]');
    return offlineHeader || null;
  }
  compareMemberOrder(elA, elB) {
    const posA = parseInt(elA.getAttribute("data-role-position") || "0", 10);
    const posB = parseInt(elB.getAttribute("data-role-position") || "0", 10);
    if (posA !== posB)
      return posB - posA;
    const nameA = (elA.getAttribute("data-display-name") || "").toLowerCase();
    const nameB = (elB.getAttribute("data-display-name") || "").toLowerCase();
    return nameA < nameB ? -1 : nameA > nameB ? 1 : 0;
  }
  moveMemberToGroup(el, group) {
    const header = this.ensureGroupHeader(group);
    let sibling = header.nextElementSibling;
    let insertBefore = null;
    while (sibling && !sibling.hasAttribute("data-status-group")) {
      if (sibling.hasAttribute("data-user-id") && sibling !== el) {
        if (this.compareMemberOrder(el, sibling) < 0) {
          insertBefore = sibling;
          break;
        }
      }
      sibling = sibling.nextElementSibling;
    }
    if (insertBefore) {
      if (el.nextElementSibling === insertBefore)
        return;
      header.parentNode.insertBefore(el, insertBefore);
    } else {
      const nextHeader = this.findNextGroupHeader(header);
      if (nextHeader) {
        if (el.nextElementSibling === nextHeader)
          return;
        header.parentNode.insertBefore(el, nextHeader);
      } else {
        this.listTarget.appendChild(el);
      }
    }
  }
  insertMemberInGroup(el, group) {
    this.listTarget.appendChild(el);
    this.moveMemberToGroup(el, group);
  }
  findNextGroupHeader(header) {
    let sibling = header.nextElementSibling;
    while (sibling) {
      if (sibling.hasAttribute("data-status-group"))
        return sibling;
      sibling = sibling.nextElementSibling;
    }
    return null;
  }
  recountAllGroups() {
    const headers = this.getAllGroupHeaders();
    for (const header of headers) {
      const members = this.getGroupMembers(header);
      if (members.length === 0) {
        header.remove();
      } else {
        const group = header.getAttribute("data-status-group");
        const currentText = header.textContent;
        const dashIdx = currentText.indexOf(" — ");
        const label = dashIdx >= 0 ? currentText.substring(0, dashIdx).trim() : currentText.trim();
        header.textContent = `${label} — ${members.length}`;
      }
    }
  }
}

// app/javascript/controllers/profile_card_controller.js
class profile_card_controller_default extends Controller {
  static values = { serverId: String };
  connect() {
    this.card = null;
    this.boundClose = this.closeCard.bind(this);
  }
  disconnect() {
    this.closeCard();
  }
  async show(event) {
    event.preventDefault();
    event.stopPropagation();
    this.closeCard();
    const target = event.currentTarget;
    const userId = target.dataset.userId;
    if (!userId || !this.serverIdValue)
      return;
    const response = await fetch(`/servers/${this.serverIdValue}/members/${userId}/profile_card`, {
      headers: { "X-Requested-With": "XMLHttpRequest" }
    });
    if (!response.ok)
      return;
    const html = await response.text();
    this.card = document.createElement("div");
    this.card.className = "fixed z-50";
    this.card.innerHTML = html;
    const rect = target.getBoundingClientRect();
    let left = rect.left - 288;
    let top = rect.top;
    if (left < 8)
      left = rect.right + 8;
    if (top + 400 > window.innerHeight)
      top = window.innerHeight - 400;
    this.card.style.left = `${Math.max(8, left)}px`;
    this.card.style.top = `${Math.max(8, top)}px`;
    document.body.appendChild(this.card);
    setTimeout(() => document.addEventListener("click", this.boundClose), 10);
  }
  closeCard(event) {
    if (this.card) {
      if (event && this.card.contains(event.target))
        return;
      this.card.remove();
      this.card = null;
    }
    document.removeEventListener("click", this.boundClose);
  }
}

// app/javascript/controllers/appearance_controller.js
class appearance_controller_default extends Controller {
  connect() {
    this.idleTimeout = null;
    this.pingInterval = null;
    this.isIdle = false;
    this.IDLE_MS = 15 * 60 * 1000;
    this.PING_MS = 30 * 1000;
    this.subscription = createConsumer3().subscriptions.create({ channel: "AppearanceChannel" }, {
      connected: () => {
        this.startIdleDetection();
        this.startPing();
        this.updateUserPanelDot("online");
      },
      disconnected: () => {
        this.stopIdleDetection();
        this.stopPing();
        this.updateUserPanelDot("offline");
      }
    });
  }
  disconnect() {
    this.stopIdleDetection();
    this.stopPing();
    if (this.subscription)
      this.subscription.unsubscribe();
  }
  startPing() {
    this.stopPing();
    this.pingInterval = setInterval(() => {
      this.subscription.perform("ping", { state: this.isIdle ? "idle" : "online" });
    }, this.PING_MS);
  }
  stopPing() {
    if (this.pingInterval) {
      clearInterval(this.pingInterval);
      this.pingInterval = null;
    }
  }
  startIdleDetection() {
    this.resetIdle();
    this.boundReset = this.resetIdle.bind(this);
    document.addEventListener("mousemove", this.boundReset);
    document.addEventListener("keydown", this.boundReset);
    document.addEventListener("click", this.boundReset);
    this.boundVisibility = () => {
      if (document.hidden)
        this.goIdle();
      else
        this.resetIdle();
    };
    document.addEventListener("visibilitychange", this.boundVisibility);
  }
  stopIdleDetection() {
    clearTimeout(this.idleTimeout);
    if (this.boundReset) {
      document.removeEventListener("mousemove", this.boundReset);
      document.removeEventListener("keydown", this.boundReset);
      document.removeEventListener("click", this.boundReset);
    }
    if (this.boundVisibility) {
      document.removeEventListener("visibilitychange", this.boundVisibility);
    }
  }
  resetIdle() {
    clearTimeout(this.idleTimeout);
    if (this.isIdle) {
      this.isIdle = false;
      this.subscription.perform("back");
      this.updateUserPanelDot("online");
    }
    this.idleTimeout = setTimeout(() => this.goIdle(), this.IDLE_MS);
  }
  goIdle() {
    if (!this.isIdle) {
      this.isIdle = true;
      this.subscription.perform("away");
      this.updateUserPanelDot("idle");
    }
  }
  updateUserPanelDot(state) {
    const colorMap = { online: "bg-green-500", idle: "bg-yellow-500", dnd: "bg-red-500", offline: "bg-gray-500" };
    const dots = document.querySelectorAll("[data-user-status-dot]");
    dots.forEach((dot) => {
      dot.classList.remove("bg-green-500", "bg-yellow-500", "bg-red-500", "bg-gray-500");
      dot.classList.add(colorMap[state] || "bg-gray-500");
    });
  }
}

// app/javascript/controllers/mention_autocomplete_controller.js
class mention_autocomplete_controller_default extends Controller {
  static values = { serverId: String };
  static targets = ["input", "popup"];
  connect() {
    this.selectedIndex = 0;
    this.results = [];
    this.mentionStart = -1;
  }
  onInput(event) {
    const input = this.inputTarget;
    const value = input.value;
    const cursor = input.selectionStart;
    const beforeCursor = value.substring(0, cursor);
    const atIndex = beforeCursor.lastIndexOf("@");
    if (atIndex === -1 || atIndex > 0 && beforeCursor[atIndex - 1] !== " " && beforeCursor[atIndex - 1] !== `
`) {
      this.hidePopup();
      return;
    }
    const query = beforeCursor.substring(atIndex + 1);
    if (query.includes(" ") || query.length > 20) {
      this.hidePopup();
      return;
    }
    this.mentionStart = atIndex;
    this.fetchResults(query);
  }
  async fetchResults(query) {
    if (!this.serverIdValue)
      return;
    const response = await fetch(`/servers/${this.serverIdValue}/mentions?q=${encodeURIComponent(query)}`);
    if (!response.ok)
      return;
    this.results = await response.json();
    this.selectedIndex = 0;
    this.renderPopup();
  }
  renderPopup() {
    if (this.results.length === 0) {
      this.hidePopup();
      return;
    }
    let html = this.results.map((r, i) => {
      const selected = i === this.selectedIndex ? "bg-gray-600" : "";
      let icon = "";
      let detail = "";
      if (r.type === "user") {
        icon = `<div class="w-6 h-6 rounded-full bg-orange-600 flex items-center justify-center text-xs font-bold text-white shrink-0">${r.name[0].toUpperCase()}</div>`;
        detail = `<span class="text-xs text-gray-500">#${r.discriminator}</span>`;
      } else if (r.type === "role") {
        const color = r.color || "#99aab5";
        icon = `<div class="w-6 h-6 rounded-full flex items-center justify-center shrink-0" style="background:${color}30;border:2px solid ${color}"><span class="text-xs" style="color:${color}">R</span></div>`;
      } else {
        icon = `<div class="w-6 h-6 rounded-full bg-yellow-600 flex items-center justify-center text-xs font-bold text-white shrink-0">@</div>`;
        detail = `<span class="text-xs text-gray-500">${r.description || ""}</span>`;
      }
      return `<div class="flex items-center gap-2 px-3 py-1.5 cursor-pointer hover:bg-gray-600 rounded ${selected}" data-index="${i}" data-action="click->mention-autocomplete#selectResult mouseenter->mention-autocomplete#hoverResult">
        ${icon}
        <span class="text-sm text-white font-medium">${r.display}</span>
        ${detail}
      </div>`;
    }).join("");
    this.popupTarget.innerHTML = html;
    this.popupTarget.classList.remove("hidden");
  }
  hidePopup() {
    this.popupTarget.classList.add("hidden");
    this.results = [];
    this.mentionStart = -1;
  }
  onKeydown(event) {
    if (this.results.length === 0)
      return;
    if (event.key === "ArrowDown") {
      event.preventDefault();
      this.selectedIndex = (this.selectedIndex + 1) % this.results.length;
      this.renderPopup();
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      this.selectedIndex = (this.selectedIndex - 1 + this.results.length) % this.results.length;
      this.renderPopup();
    } else if (event.key === "Enter" || event.key === "Tab") {
      if (this.results.length > 0 && this.mentionStart >= 0) {
        event.preventDefault();
        event.stopPropagation();
        this.insertMention(this.results[this.selectedIndex]);
      }
    } else if (event.key === "Escape") {
      this.hidePopup();
    }
  }
  selectResult(event) {
    const index = parseInt(event.currentTarget.dataset.index);
    this.insertMention(this.results[index]);
  }
  hoverResult(event) {
    this.selectedIndex = parseInt(event.currentTarget.dataset.index);
    this.renderPopup();
  }
  insertMention(result) {
    const input = this.inputTarget;
    const value = input.value;
    const cursor = input.selectionStart;
    const before = value.substring(0, this.mentionStart);
    const after = value.substring(cursor);
    const mention = `@${result.name} `;
    input.value = before + mention + after;
    input.selectionStart = input.selectionEnd = before.length + mention.length;
    input.focus();
    this.hidePopup();
  }
}

// app/javascript/controllers/notification_badge_controller.js
class notification_badge_controller_default extends Controller {
  connect() {
    this.subscription = createConsumer3().subscriptions.create({ channel: "NotificationChannel" }, {
      received: (data) => this.handleNotification(data)
    });
    this.clearCurrentChannelBadges();
    this._restoreLastChannels();
    this.sidebarTyping = new Map;
    this.handleContextMenu = this.handleContextMenu.bind(this);
    document.addEventListener("contextmenu", this.handleContextMenu);
    this.closeMenu = this.closeMenu.bind(this);
    document.addEventListener("click", this.closeMenu);
    this._beforeCache = () => this._cleanupForCache();
    document.addEventListener("turbo:before-cache", this._beforeCache);
    this._onRender = () => this.clearCurrentChannelBadges();
    document.addEventListener("turbo:render", this._onRender);
  }
  disconnect() {
    if (this.subscription)
      this.subscription.unsubscribe();
    document.removeEventListener("contextmenu", this.handleContextMenu);
    document.removeEventListener("click", this.closeMenu);
    this.closeMenu();
    if (this._beforeCache)
      document.removeEventListener("turbo:before-cache", this._beforeCache);
    if (this._onRender)
      document.removeEventListener("turbo:render", this._onRender);
    if (this.sidebarTyping) {
      this.sidebarTyping.forEach((users) => users.forEach((u) => clearTimeout(u.timeout)));
      this.sidebarTyping.clear();
    }
  }
  _cleanupForCache() {
    document.querySelectorAll(".typing-indicator").forEach((el) => el.remove());
    document.querySelectorAll(".server-unread-pill").forEach((el) => el.remove());
    document.querySelectorAll(".mention-badge").forEach((el) => el.remove());
    document.querySelectorAll(".home-badge").forEach((el) => el.remove());
    document.querySelectorAll("[data-channel-id][data-unread]").forEach((el) => {
      delete el.dataset.unread;
      const pill = el.querySelector(".unread-pill");
      if (pill)
        pill.remove();
      if (!el.classList.contains("bg-gray-600")) {
        el.classList.remove("text-white");
        el.classList.add("text-gray-400");
      }
      const nameSpan = el.querySelector(".truncate");
      if (nameSpan) {
        nameSpan.classList.remove("font-bold");
        nameSpan.classList.add("font-medium");
      }
    });
  }
  _restoreLastChannels() {
    try {
      document.querySelectorAll("a[data-server-id]").forEach((el) => {
        const serverId = el.dataset.serverId;
        const lastChannel = localStorage.getItem(`lastChannel_${serverId}`);
        if (lastChannel) {
          el.href = el.href.replace(/\/channels\/[^\/]+/, `/channels/${lastChannel}`);
        }
      });
    } catch (e) {
    }
  }
  get canManage() {
    const el = document.querySelector("[data-channel-reorder-can-manage-value]");
    return el?.dataset?.channelReorderCanManageValue === "true";
  }
  get currentServerId() {
    return document.querySelector("[data-current-server-id]")?.dataset?.currentServerId;
  }
  handleNotification(data) {
    if (data.type === "mention") {
      const currentChannelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId;
      if (currentChannelId && String(data.channel_id) === String(currentChannelId))
        return;
      this.showServerBadge(data.server_id);
      this.showChannelBadge(data.channel_id);
    } else if (data.type === "dm_message") {
      const currentConvEl = document.querySelector("[data-dm-message-form-conversation-id-value]");
      const currentConvId = currentConvEl?.dataset?.dmMessageFormConversationIdValue;
      if (currentConvId && String(data.conversation_id) === String(currentConvId))
        return;
      this.showHomeBadge();
      this.showConversationBadge(data.conversation_id);
    } else if (data.type === "friend_request") {
      this.showHomeBadge();
    } else if (data.type === "channel_message") {
      const selfId = document.body.dataset.currentUserId;
      if (data.user_id && String(data.user_id) === String(selfId))
        return;
      const currentChannelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId;
      if (currentChannelId && String(data.channel_id) === String(currentChannelId))
        return;
      this.showChannelUnread(data.channel_id);
      this.showServerUnread(data.server_id);
    } else if (data.type === "channel_typing") {
      this._handleChannelTyping(data);
    } else if (data.type === "clear") {
      if (data.channel_id)
        this.removeBadge("channel", data.channel_id);
      if (data.server_id && !data.channel_id)
        this.removeServerBadge(data.server_id);
    }
  }
  clearCurrentChannelBadges() {
    const el = document.querySelector("[data-current-channel-id]");
    if (!el)
      return;
    const channelId = el.dataset.currentChannelId;
    const serverId = el.dataset.currentServerId;
    if (channelId) {
      this.removeBadge("channel", channelId);
      this.removeChannelUnread(channelId);
    }
    if (serverId) {
      this.recountServerBadge(serverId);
      this.recountServerUnread(serverId);
    }
  }
  showHomeBadge() {
    const homeBtn = document.querySelector("[data-home-button]");
    if (!homeBtn)
      return;
    let badge = homeBtn.querySelector(".home-badge");
    if (!badge) {
      badge = document.createElement("div");
      badge.className = "home-badge mention-badge absolute -bottom-0.5 -right-0.5 min-w-[18px] h-[18px] bg-red-500 rounded-full flex items-center justify-center text-white text-xs font-bold px-1 border-2 border-gray-950";
      badge.textContent = "1";
      homeBtn.appendChild(badge);
    } else {
      const count = parseInt(badge.textContent || "0") + 1;
      badge.textContent = count > 99 ? "99+" : count;
    }
  }
  removeHomeBadge() {
    const homeBtn = document.querySelector("[data-home-button]");
    if (!homeBtn)
      return;
    const badge = homeBtn.querySelector(".home-badge");
    if (badge)
      badge.remove();
  }
  showConversationBadge(conversationId) {
    const convEl = document.querySelector(`[data-conversation-id="${conversationId}"]`);
    if (!convEl)
      return;
    let badge = convEl.querySelector(".mention-badge");
    if (!badge) {
      badge = document.createElement("div");
      badge.className = "mention-badge ml-auto min-w-[18px] h-[18px] bg-red-500 rounded-full flex items-center justify-center text-white text-xs font-bold px-1 shrink-0";
      badge.textContent = "1";
      convEl.appendChild(badge);
    } else {
      const count = parseInt(badge.textContent || "0") + 1;
      badge.textContent = count > 99 ? "99+" : count;
    }
  }
  removeConversationBadge(conversationId) {
    const convEl = document.querySelector(`[data-conversation-id="${conversationId}"]`);
    if (!convEl)
      return;
    const badge = convEl.querySelector(".mention-badge");
    if (badge)
      badge.remove();
  }
  recountHomeBadge() {
    let total = 0;
    document.querySelectorAll("[data-conversation-id] .mention-badge").forEach((badge2) => {
      total += parseInt(badge2.textContent || "0");
    });
    const homeBtn = document.querySelector("[data-home-button]");
    if (!homeBtn)
      return;
    const badge = homeBtn.querySelector(".home-badge");
    if (total <= 0) {
      if (badge)
        badge.remove();
    } else if (badge) {
      badge.textContent = total > 99 ? "99+" : total;
    }
  }
  async markDmsAsRead(conversationId) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    const params = new URLSearchParams;
    if (conversationId)
      params.append("conversation_id", conversationId);
    await fetch("/notifications/mark_dm_read", {
      method: "POST",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/x-www-form-urlencoded" },
      body: params.toString()
    });
    if (conversationId) {
      this.removeConversationBadge(conversationId);
      this.recountHomeBadge();
    } else {
      document.querySelectorAll("[data-conversation-id] .mention-badge").forEach((b) => b.remove());
      this.removeHomeBadge();
    }
  }
  showServerBadge(serverId) {
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`);
    if (!serverIcon)
      return;
    let badge = serverIcon.querySelector(".mention-badge");
    if (!badge) {
      badge = document.createElement("div");
      badge.className = "mention-badge absolute -bottom-0.5 -right-0.5 min-w-[18px] h-[18px] bg-red-500 rounded-full flex items-center justify-center text-white text-xs font-bold px-1 border-2 border-gray-950";
      badge.textContent = "1";
      serverIcon.style.position = "relative";
      serverIcon.appendChild(badge);
    } else {
      const count = parseInt(badge.textContent || "0") + 1;
      badge.textContent = count > 99 ? "99+" : count;
    }
  }
  showChannelBadge(channelId) {
    const channelItem = document.querySelector(`[data-channel-id="${channelId}"]`);
    if (!channelItem)
      return;
    let badge = channelItem.querySelector(".mention-badge");
    if (!badge) {
      badge = document.createElement("div");
      badge.className = "mention-badge ml-auto min-w-[18px] h-[18px] bg-red-500 rounded-full flex items-center justify-center text-white text-xs font-bold px-1 shrink-0";
      badge.textContent = "1";
      channelItem.appendChild(badge);
    } else {
      const count = parseInt(badge.textContent || "0") + 1;
      badge.textContent = count > 99 ? "99+" : count;
    }
  }
  removeBadge(type, id) {
    const attr = type === "server" ? "data-server-id" : "data-channel-id";
    const el = document.querySelector(`[${attr}="${id}"]`);
    if (!el)
      return;
    const badge = el.querySelector(".mention-badge");
    if (badge)
      badge.remove();
  }
  removeServerBadge(serverId) {
    this.removeBadge("server", serverId);
    document.querySelectorAll(`[data-channel-id] .mention-badge`).forEach((b) => b.remove());
  }
  recountServerBadge(serverId) {
    let total = 0;
    document.querySelectorAll(`[data-channel-id] .mention-badge`).forEach((badge) => {
      total += parseInt(badge.textContent || "0");
    });
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`);
    if (!serverIcon)
      return;
    const serverBadge = serverIcon.querySelector(".mention-badge");
    if (total <= 0) {
      if (serverBadge)
        serverBadge.remove();
    } else if (serverBadge) {
      serverBadge.textContent = total > 99 ? "99+" : total;
    }
  }
  showChannelUnread(channelId) {
    const channelItem = document.querySelector(`[data-channel-id="${channelId}"]`);
    if (!channelItem)
      return;
    if (channelItem.dataset.unread === "true")
      return;
    channelItem.dataset.unread = "true";
    channelItem.classList.remove("text-gray-400");
    channelItem.classList.add("text-white");
    const nameSpan = channelItem.querySelector(".truncate");
    if (nameSpan) {
      nameSpan.classList.remove("font-medium");
      nameSpan.classList.add("font-bold");
    }
    if (!channelItem.querySelector(".unread-pill")) {
      const pill = document.createElement("div");
      pill.className = "unread-pill absolute -left-2 top-1/2 -translate-y-1/2 w-1 h-2 bg-gray-300 rounded-r-full";
      channelItem.appendChild(pill);
    }
  }
  removeChannelUnread(channelId) {
    const channelItem = document.querySelector(`[data-channel-id="${channelId}"]`);
    if (!channelItem)
      return;
    delete channelItem.dataset.unread;
    const isActive = channelItem.classList.contains("bg-gray-600");
    if (!isActive) {
      channelItem.classList.remove("text-white");
      channelItem.classList.add("text-gray-400");
    }
    const nameSpan = channelItem.querySelector(".truncate");
    if (nameSpan) {
      nameSpan.classList.remove("font-bold");
      nameSpan.classList.add("font-medium");
    }
    const pill = channelItem.querySelector(".unread-pill");
    if (pill)
      pill.remove();
  }
  showServerUnread(serverId) {
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`);
    if (!serverIcon)
      return;
    if (serverIcon.querySelector(".mention-badge"))
      return;
    if (serverIcon.querySelector(".server-unread-pill"))
      return;
    if (serverIcon.classList.contains("bg-orange-600"))
      return;
    const pill = document.createElement("div");
    pill.className = "server-unread-pill absolute left-0 top-1/2 -translate-x-[22px] -translate-y-1/2 w-1 h-2 bg-white rounded-r-full";
    serverIcon.appendChild(pill);
  }
  removeServerUnread(serverId) {
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`);
    if (!serverIcon)
      return;
    const pill = serverIcon.querySelector(".server-unread-pill");
    if (pill)
      pill.remove();
  }
  recountServerUnread(serverId) {
    const hasUnread = document.querySelector("[data-channel-id][data-unread='true']") !== null;
    const serverIcon = document.querySelector(`[data-server-id="${serverId}"]`);
    if (!serverIcon)
      return;
    if (!hasUnread) {
      this.removeServerUnread(serverId);
    } else if (!serverIcon.querySelector(".mention-badge")) {
      this.showServerUnread(serverId);
    }
  }
  _handleChannelTyping(data) {
    const channelId = data.channel_id;
    if (!this.sidebarTyping.has(channelId)) {
      this.sidebarTyping.set(channelId, new Map);
    }
    const users = this.sidebarTyping.get(channelId);
    const existing = users.get(data.user_id);
    if (existing)
      clearTimeout(existing.timeout);
    const timeout = setTimeout(() => {
      users.delete(data.user_id);
      if (users.size === 0)
        this.sidebarTyping.delete(channelId);
      this._renderSidebarTyping(channelId);
    }, 3000);
    users.set(data.user_id, {
      username: data.username,
      avatar_url: data.avatar_url,
      avatar_initial: data.avatar_initial,
      avatar_color: data.avatar_color,
      timeout
    });
    this._renderSidebarTyping(channelId);
  }
  _renderSidebarTyping(channelId) {
    const channelItem = document.querySelector(`[data-channel-id="${channelId}"]`);
    if (!channelItem)
      return;
    const existingIndicator = channelItem.querySelector(".typing-indicator");
    const users = this.sidebarTyping.get(channelId);
    if (!users || users.size === 0) {
      if (existingIndicator)
        existingIndicator.remove();
      return;
    }
    this._ensureTypingStyles();
    const userList = Array.from(users.values());
    const maxVisible = 2;
    const visible = userList.slice(0, maxVisible);
    const extra = userList.length - maxVisible;
    let html = '<div class="flex items-center">';
    html += '<div class="flex items-center" style="margin-left: auto;">';
    visible.forEach((u, i) => {
      const offset = i > 0 ? "margin-left: -4px;" : "";
      if (u.avatar_url) {
        html += `<img src="${u.avatar_url}" class="rounded-full object-cover shrink-0" style="width: 16px; height: 16px; ${offset} border: 1.5px solid #2b2d31; position: relative; z-index: ${maxVisible - i};" alt="${u.username}">`;
      } else {
        html += `<div class="rounded-full shrink-0 flex items-center justify-center text-white" style="width: 16px; height: 16px; font-size: 8px; ${offset} border: 1.5px solid #2b2d31; position: relative; z-index: ${maxVisible - i}; background-color: ${u.avatar_color || "#5865f2"};">${u.avatar_initial || "?"}</div>`;
      }
    });
    if (extra > 0) {
      html += `<span class="text-[9px] text-gray-400 font-semibold" style="margin-left: 2px;">+${extra}</span>`;
    }
    html += "</div>";
    html += '<span class="typing-dots" style="margin-left: 3px; font-size: 10px; color: #9ca3af;"><span>.</span><span>.</span><span>.</span></span>';
    html += "</div>";
    let indicator = existingIndicator;
    if (!indicator) {
      indicator = document.createElement("div");
      indicator.className = "typing-indicator ml-auto shrink-0";
      channelItem.appendChild(indicator);
    }
    indicator.innerHTML = html;
  }
  _ensureTypingStyles() {
    if (document.getElementById("typing-dots-style"))
      return;
    const style = document.createElement("style");
    style.id = "typing-dots-style";
    style.textContent = `
      .typing-dots span {
        animation: typingDot 1.4s infinite;
        display: inline-block;
      }
      .typing-dots span:nth-child(2) { animation-delay: 0.2s; }
      .typing-dots span:nth-child(3) { animation-delay: 0.4s; }
      @keyframes typingDot {
        0%, 60%, 100% { opacity: 0.3; }
        30% { opacity: 1; }
      }
    `;
    document.head.appendChild(style);
  }
  handleContextMenu(event) {
    if (event.target.closest("[data-context-menu]") || event.target.closest("#notif-context-menu"))
      return;
    const homeEl = event.target.closest("[data-home-button]");
    if (homeEl) {
      event.preventDefault();
      this.closeMenu();
      this.showHomeContextMenu(event.clientX, event.clientY);
      return;
    }
    const convEl = event.target.closest("[data-conversation-id]");
    if (convEl) {
      event.preventDefault();
      this.closeMenu();
      this.showConversationContextMenu(event.clientX, event.clientY, convEl.dataset.conversationId);
      return;
    }
    const serverEl = event.target.closest("[data-server-id]");
    if (serverEl) {
      event.preventDefault();
      this.closeMenu();
      this.showServerContextMenu(event.clientX, event.clientY, serverEl.dataset.serverId);
      return;
    }
    const channelEl = event.target.closest("[data-channel-id]");
    if (channelEl) {
      event.preventDefault();
      this.closeMenu();
      this.showChannelContextMenu(event.clientX, event.clientY, channelEl.dataset.channelId);
      return;
    }
    const categoryEl = event.target.closest("[data-category-id]");
    if (categoryEl) {
      event.preventDefault();
      this.closeMenu();
      this.showCategoryContextMenu(event.clientX, event.clientY, categoryEl.dataset.categoryId);
      return;
    }
    const videoEl = event.target.closest("[data-video-src]");
    if (videoEl)
      return;
    const imgEl = event.target.closest("img[data-preview-src]");
    if (imgEl) {
      return;
    }
    const messageEl = event.target.closest("[data-message-id]");
    if (messageEl) {
      event.preventDefault();
      this.closeMenu();
      this.showMessageContextMenu(event.clientX, event.clientY, messageEl, event.target);
      return;
    }
  }
  showHomeContextMenu(x, y) {
    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markDmsAsRead()
      }
    ];
    this.renderContextMenu(x, y, items);
  }
  showConversationContextMenu(x, y, conversationId) {
    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markDmsAsRead(conversationId)
      }
    ];
    this.renderContextMenu(x, y, items);
  }
  showServerContextMenu(x, y, serverId) {
    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markAsRead({ serverId })
      },
      { separator: true },
      {
        icon: this.icons.bell,
        label: "Notification Settings",
        disabled: true
      },
      { separator: true },
      {
        icon: this.icons.copy,
        label: "Copy Server ID",
        action: () => navigator.clipboard.writeText(serverId)
      }
    ];
    this.renderContextMenu(x, y, items);
  }
  showChannelContextMenu(x, y, channelId) {
    const serverId = this.currentServerId;
    const items = [
      {
        icon: this.icons.check,
        label: "Mark as Read",
        action: () => this.markAsRead({ channelId, serverId })
      },
      { separator: true },
      {
        icon: this.icons.bell,
        label: "Notification Settings",
        disabled: true
      }
    ];
    if (this.canManage) {
      items.push({ separator: true });
      items.push({
        icon: this.icons.edit,
        label: "Edit Channel",
        action: () => {
          window.location.href = `/servers/${serverId}/channels/${channelId}/edit`;
        }
      });
      items.push({
        icon: this.icons.trash,
        label: "Delete Channel",
        danger: true,
        action: () => this.deleteChannel(serverId, channelId)
      });
    }
    items.push({ separator: true });
    items.push({
      icon: this.icons.copy,
      label: "Copy Channel ID",
      action: () => navigator.clipboard.writeText(channelId)
    });
    this.renderContextMenu(x, y, items);
  }
  showCategoryContextMenu(x, y, categoryId) {
    const serverId = this.currentServerId;
    const items = [];
    if (this.canManage) {
      items.push({
        icon: this.icons.plus,
        label: "Create Channel",
        action: () => {
          window.location.href = `/servers/${serverId}/channels/new?category_id=${categoryId}`;
        }
      });
      items.push({ separator: true });
      items.push({
        icon: this.icons.edit,
        label: "Edit Category",
        action: () => {
          window.location.href = `/servers/${serverId}/categories/${categoryId}/edit`;
        }
      });
      items.push({
        icon: this.icons.trash,
        label: "Delete Category",
        danger: true,
        action: () => this.deleteCategory(serverId, categoryId)
      });
      items.push({ separator: true });
    }
    items.push({
      icon: this.icons.copy,
      label: "Copy Category ID",
      action: () => navigator.clipboard.writeText(categoryId)
    });
    this.renderContextMenu(x, y, items);
  }
  showMessageContextMenu(x, y, messageEl, clickTarget) {
    const messageId = messageEl.dataset.messageId;
    const serverId = this.currentServerId;
    const currentUserId = document.body.dataset.currentUserId;
    const authorEl = messageEl.querySelector(".text-orange-400");
    const contentEl = messageEl.querySelector(".message-content");
    const content = contentEl?.textContent?.trim() || "";
    const clickedLink = clickTarget ? clickTarget.closest("a[href]") : null;
    const isAuthor = messageEl.dataset.authorId === currentUserId;
    const items = [
      {
        icon: this.icons.reply,
        label: "Reply",
        action: () => {
          const authorName = messageEl.querySelector(".text-orange-400")?.textContent?.trim() || "";
          let rawPreview = messageEl.querySelector(".message-content")?.textContent?.trim() || "";
          const preview = rawPreview.replace(/```\w*/g, "").replace(/```/g, "").replace(/\s+/g, " ").trim().substring(0, 80);
          const event = new CustomEvent("inferno:reply", { detail: { messageId, authorName, preview }, bubbles: true });
          document.dispatchEvent(event);
        }
      },
      {
        icon: this.icons.react,
        label: "Add Reaction",
        action: () => {
          const event = new CustomEvent("inferno:react", { detail: { messageId }, bubbles: true });
          document.dispatchEvent(event);
        }
      },
      { separator: true },
      {
        icon: this.icons.copy,
        label: "Copy Text",
        action: () => navigator.clipboard.writeText(content)
      },
      {
        icon: "\uD83D\uDD0D",
        label: "View Reactions",
        action: () => this.viewReactions(messageId)
      },
      {
        icon: this.icons.link,
        label: "Copy Message Link",
        action: () => {
          const el = document.querySelector("[data-current-server-id]");
          const sId = el ? el.dataset.currentServerId : "";
          const cId = el ? el.dataset.currentChannelId : "";
          const link = `${window.location.origin}/servers/${sId}/channels/${cId}#message-${messageId}`;
          navigator.clipboard.writeText(link);
        }
      },
      {
        icon: this.icons.copy,
        label: "Copy Message ID",
        action: () => navigator.clipboard.writeText(messageId)
      }
    ];
    if (clickedLink) {
      items.unshift({
        icon: this.icons.link,
        label: "Open Link",
        action: () => window.open(clickedLink.href, "_blank")
      });
      items.unshift({
        icon: this.icons.link,
        label: "Copy Link",
        action: () => navigator.clipboard.writeText(clickedLink.href)
      });
      items.splice(2, 0, { separator: true });
    }
    if (isAuthor) {
      items.push({ separator: true });
      items.push({
        icon: this.icons.edit,
        label: "Edit Message",
        action: () => this.editMessage(messageId)
      });
      items.push({
        icon: this.icons.trash,
        label: "Delete Message",
        danger: true,
        action: () => this.deleteMessage(messageId)
      });
    } else if (this.canManage) {
      items.push({ separator: true });
      items.push({
        icon: this.icons.trash,
        label: "Delete Message",
        danger: true,
        action: () => this.deleteMessage(messageId)
      });
    }
    this.renderContextMenu(x, y, items);
  }
  async viewReactions(messageId) {
    const channelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId;
    try {
      const res = await fetch(`/channels/${channelId}/messages/${messageId}/reactions_list`);
      if (!res.ok)
        return;
      const data = await res.json();
      if (!data.length) {
        this.showToast("No reactions on this message");
        return;
      }
      const overlay = document.createElement("div");
      overlay.className = "fixed inset-0 z-[200] bg-black/60 flex items-center justify-center";
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay)
          overlay.remove();
      });
      const modal = document.createElement("div");
      modal.className = "bg-gray-800 rounded-lg shadow-xl max-w-sm w-full mx-4 overflow-hidden";
      let html = '<div class="px-4 py-3 border-b border-gray-700 flex items-center justify-between"><h3 class="text-white font-semibold">Reactions</h3><button class="text-gray-400 hover:text-white text-xl close-reactions-btn">&times;</button></div>';
      html += '<div class="px-4 py-3 max-h-80 overflow-y-auto space-y-3">';
      data.forEach((group) => {
        html += `<div><div class="text-lg mb-1">${group.emoji} <span class="text-sm text-gray-400">${group.users.length}</span></div>`;
        html += '<div class="space-y-1">';
        group.users.forEach((name) => {
          html += `<div class="text-sm text-gray-300 pl-2">${name}</div>`;
        });
        html += "</div></div>";
      });
      html += "</div>";
      modal.innerHTML = html;
      overlay.appendChild(modal);
      document.body.appendChild(overlay);
      overlay.querySelector(".close-reactions-btn")?.addEventListener("click", () => overlay.remove());
      const onKey = (e) => {
        if (e.key === "Escape") {
          overlay.remove();
          document.removeEventListener("keydown", onKey);
        }
      };
      document.addEventListener("keydown", onKey);
    } catch (e) {
      console.error("Failed to fetch reactions:", e);
    }
  }
  editMessage(messageId) {
    const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
    if (!messageEl)
      return;
    const contentEl = messageEl.querySelector(".message-content");
    if (!contentEl)
      return;
    const currentText = contentEl.dataset.rawContent || contentEl.textContent.trim();
    const channelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId;
    contentEl.dataset.originalHtml = contentEl.innerHTML;
    contentEl.innerHTML = `
      <form class="flex gap-2 items-center" data-edit-message-id="${messageId}">
        <input type="text" value="${currentText.replace(/"/g, "&quot;")}" 
               class="flex-1 bg-gray-900 border border-gray-600 rounded px-2 py-1 text-sm text-white focus:outline-none focus:border-indigo-500"
               autofocus>
        <button type="submit" class="text-xs text-green-400 hover:text-green-300">Save</button>
        <button type="button" class="text-xs text-gray-400 hover:text-gray-200 cancel-edit-btn">Cancel</button>
      </form>
    `;
    const fileContainer = messageEl.querySelector(".flex.flex-wrap.gap-2.mt-2");
    const removeFileIds = [];
    if (fileContainer) {
      fileContainer.querySelectorAll("img").forEach((img) => {
        const wrapper = img.parentElement;
        if (wrapper.querySelector(".remove-attachment-btn"))
          return;
        wrapper.style.position = "relative";
        const removeBtn = document.createElement("button");
        removeBtn.type = "button";
        removeBtn.className = "remove-attachment-btn absolute top-1 right-1 bg-red-600 hover:bg-red-500 text-white rounded-full w-6 h-6 flex items-center justify-center text-xs font-bold z-10";
        removeBtn.innerHTML = "×";
        removeBtn.addEventListener("click", () => {
          const src = img.dataset.previewSrc || img.src;
          const blobMatch = src.match(/\/blobs\/([^\/]+)/);
          if (blobMatch) {
            removeBtn.dataset.blobId = blobMatch[1];
          }
          const attachId = img.closest("[data-attachment-id]")?.dataset?.attachmentId;
          if (attachId)
            removeFileIds.push(attachId);
          wrapper.style.opacity = "0.3";
          wrapper.style.pointerEvents = "none";
          removeBtn.remove();
        });
        wrapper.appendChild(removeBtn);
      });
    }
    const cancelBtn = contentEl.querySelector(".cancel-edit-btn");
    cancelBtn.addEventListener("click", () => {
      contentEl.innerHTML = contentEl.dataset.originalHtml;
      if (fileContainer) {
        fileContainer.querySelectorAll(".remove-attachment-btn").forEach((b) => b.remove());
        fileContainer.querySelectorAll("[style]").forEach((el) => {
          el.style.opacity = "";
          el.style.pointerEvents = "";
          el.style.position = "";
        });
      }
    });
    const input = contentEl.querySelector("input");
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
    const form = contentEl.querySelector("form");
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const newContent = input.value.trim();
      if (!newContent && removeFileIds.length === 0) {
        if (await this.showConfirm("Delete Message", "Message is empty. Delete this message?")) {
          contentEl.innerHTML = contentEl.dataset.originalHtml;
          this.deleteMessage(messageId, true);
        }
        return;
      }
      const csrf = document.querySelector("meta[name=csrf-token]")?.content;
      const payload = { message: { content: newContent } };
      if (removeFileIds.length > 0) {
        payload.message.remove_file_ids = removeFileIds;
      }
      const blobBtns = fileContainer?.querySelectorAll('[style*="opacity: 0.3"]');
      const res = await fetch(`/channels/${channelId}/messages/${messageId}`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json", Accept: "text/html" },
        body: JSON.stringify(payload)
      });
      if (res.ok) {
      }
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        cancelBtn.click();
      }
    });
  }
  async deleteMessage(messageId, skipConfirm = false) {
    if (!skipConfirm && !await this.showConfirm("Delete Message", "Are you sure you want to delete this message? This cannot be undone."))
      return;
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    const channelId = document.querySelector("[data-current-channel-id]")?.dataset?.currentChannelId;
    const conversationId = document.querySelector("[data-dm-message-form-conversation-id-value]")?.dataset?.dmMessageFormConversationIdValue;
    let url;
    if (channelId) {
      url = `/channels/${channelId}/messages/${messageId}`;
    } else if (conversationId) {
      url = `/conversations/${conversationId}/dm_messages/${messageId}`;
    } else {
      return;
    }
    await fetch(url, {
      method: "DELETE",
      headers: { "X-CSRF-Token": csrf }
    });
  }
  renderContextMenu(x, y, items) {
    const menu = document.createElement("div");
    menu.className = "fixed z-[100] bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1.5 px-1.5 min-w-[200px]";
    menu.id = "notif-context-menu";
    menu.style.left = `${x}px`;
    menu.style.top = `${y}px`;
    items.forEach((item) => {
      if (item.separator) {
        const sep = document.createElement("div");
        sep.className = "border-t border-gray-700 my-1";
        menu.appendChild(sep);
        return;
      }
      const btn = document.createElement("button");
      const baseClass = "flex items-center w-full px-2.5 py-1.5 text-sm rounded cursor-pointer";
      if (item.disabled) {
        btn.className = `${baseClass} text-gray-500 cursor-not-allowed`;
      } else if (item.danger) {
        btn.className = `${baseClass} text-red-400 hover:bg-red-600/20 hover:text-red-300`;
      } else {
        btn.className = `${baseClass} text-gray-300 hover:bg-gray-700 hover:text-white`;
      }
      btn.innerHTML = `${item.icon}${item.label}${item.disabled ? '<span class="ml-auto text-xs text-gray-600">Soon</span>' : ""}`;
      if (!item.disabled && item.action) {
        btn.addEventListener("click", () => {
          item.action();
          this.closeMenu();
        });
      }
      menu.appendChild(btn);
    });
    document.body.appendChild(menu);
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth)
      menu.style.left = `${window.innerWidth - rect.width - 8}px`;
    if (rect.bottom > window.innerHeight)
      menu.style.top = `${window.innerHeight - rect.height - 8}px`;
  }
  closeMenu() {
    const existing = document.getElementById("notif-context-menu");
    if (existing)
      existing.remove();
  }
  async markAsRead({ serverId, channelId }) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    const params = new URLSearchParams;
    if (serverId)
      params.append("server_id", serverId);
    if (channelId)
      params.append("channel_id", channelId);
    await fetch("/notifications/mark_read", {
      method: "POST",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/x-www-form-urlencoded" },
      body: params.toString()
    });
    if (channelId) {
      this.removeBadge("channel", channelId);
      this.removeChannelUnread(channelId);
      if (serverId) {
        this.recountServerBadge(serverId);
        this.recountServerUnread(serverId);
      }
    } else if (serverId) {
      this.removeServerBadge(serverId);
      document.querySelectorAll("[data-channel-id]").forEach((el) => {
        this.removeChannelUnread(el.dataset.channelId);
      });
      this.removeServerUnread(serverId);
    }
  }
  async deleteChannel(serverId, channelId) {
    if (!await this.showConfirm("Delete Channel", "Are you sure? All messages in this channel will be permanently deleted."))
      return;
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    const res = await fetch(`/servers/${serverId}/channels/${channelId}/quick_delete`, {
      method: "DELETE",
      headers: { "X-CSRF-Token": csrf }
    });
    if (res.ok) {
      const el = document.querySelector(`[data-channel-id="${channelId}"]`);
      if (el)
        el.remove();
    }
  }
  async deleteCategory(serverId, categoryId) {
    if (!await this.showConfirm("Delete Category", "Are you sure? Channels in this category will become uncategorized."))
      return;
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    const res = await fetch(`/servers/${serverId}/categories/${categoryId}/quick_delete`, {
      method: "DELETE",
      headers: { "X-CSRF-Token": csrf }
    });
    if (res.ok) {
      const el = document.querySelector(`[data-category-id="${categoryId}"]`);
      if (el) {
        const channels = el.querySelectorAll("[data-channel-id]");
        const firstCategory = document.querySelector("[data-category-id]");
        channels.forEach((ch) => {
          if (firstCategory && firstCategory !== el)
            firstCategory.before(ch);
          else
            document.querySelector("[data-controller*='channel-sidebar']")?.prepend(ch);
        });
        el.remove();
      }
    }
  }
  get icons() {
    return {
      check: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/></svg>',
      bell: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"/></svg>',
      link: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-1.102-4.243a4 4 0 015.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/></svg>',
      copy: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>',
      edit: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>',
      trash: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>',
      reply: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"/></svg>',
      react: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.828 14.828a4 4 0 01-5.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>',
      plus: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/></svg>'
    };
  }
  showConfirm(title, message, confirmText = "Delete", confirmClass = "bg-red-600 hover:bg-red-700") {
    return new Promise((resolve) => {
      const overlay = document.createElement("div");
      overlay.className = "fixed inset-0 z-[200] bg-black/70 flex items-center justify-center";
      overlay.id = "confirm-modal";
      const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = s;
        return d.innerHTML;
      };
      overlay.innerHTML = `
        <div class="bg-gray-800 rounded-lg shadow-2xl w-full max-w-md mx-4 overflow-hidden">
          <div class="p-4">
            <h3 class="text-xl font-bold text-white mb-2">${esc(title)}</h3>
            <p class="text-sm text-gray-300">${esc(message)}</p>
          </div>
          <div class="px-4 py-3 flex justify-end gap-3" style="background-color: #2b2d31;">
            <button id="confirm-cancel" class="px-4 py-2 text-sm font-medium text-white hover:underline cursor-pointer">Cancel</button>
            <button id="confirm-ok" class="px-4 py-2 text-sm font-medium text-white rounded ${confirmClass} cursor-pointer">${esc(confirmText)}</button>
          </div>
        </div>
      `;
      document.body.appendChild(overlay);
      const cleanup = (result) => {
        overlay.remove();
        resolve(result);
      };
      overlay.querySelector("#confirm-ok").addEventListener("click", () => cleanup(true));
      overlay.querySelector("#confirm-cancel").addEventListener("click", () => cleanup(false));
      overlay.addEventListener("click", (e) => {
        if (e.target === overlay)
          cleanup(false);
      });
      const escHandler = (e) => {
        if (e.key === "Escape") {
          cleanup(false);
          document.removeEventListener("keydown", escHandler);
        }
      };
      document.addEventListener("keydown", escHandler);
      overlay.querySelector("#confirm-ok").focus();
    });
  }
}

// app/javascript/controllers/member_context_controller.js
class member_context_controller_default extends Controller {
  static values = { serverId: String };
  connect() {
    this.menu = null;
    this.rolesDropdown = null;
    this.nicknameModal = null;
    this.boundClose = this.closeMenu.bind(this);
  }
  disconnect() {
    this.closeMenu();
    this.closeNicknameModal();
  }
  async show(event) {
    event.preventDefault();
    event.stopPropagation();
    this.closeMenu();
    const target = event.currentTarget;
    const userId = target.dataset.userId;
    if (!userId || !this.serverIdValue)
      return;
    const response = await fetch(`/servers/${this.serverIdValue}/members/${userId}/context_menu`, {
      headers: { "X-Requested-With": "XMLHttpRequest" }
    });
    if (!response.ok)
      return;
    const html = await response.text();
    this.menu = document.createElement("div");
    this.menu.className = "fixed z-[60]";
    this.menu.setAttribute("data-context-menu", "member");
    this.menu.innerHTML = html;
    let left = event.clientX;
    let top = event.clientY;
    if (left + 220 > window.innerWidth)
      left = window.innerWidth - 220;
    if (top + 300 > window.innerHeight)
      top = window.innerHeight - 300;
    this.menu.style.left = `${left}px`;
    this.menu.style.top = `${top}px`;
    document.body.appendChild(this.menu);
    this.bindMenuActions();
    setTimeout(() => document.addEventListener("click", this.boundClose), 10);
  }
  bindMenuActions() {
    if (!this.menu)
      return;
    this.menu.querySelectorAll("[data-context-action]").forEach((btn) => {
      const action = btn.dataset.contextAction;
      if (action === "showRoles") {
        btn.addEventListener("click", (e) => this.showRoles(e));
      } else if (action === "changeNickname") {
        btn.addEventListener("click", (e) => this.changeNickname(e));
      }
    });
  }
  showRoles(event) {
    event.preventDefault();
    event.stopPropagation();
    if (this.rolesDropdown) {
      this.rolesDropdown.remove();
      this.rolesDropdown = null;
      return;
    }
    const btn = event.currentTarget;
    const memberId = btn.dataset.memberId;
    const serverId = btn.dataset.serverId;
    const roles = JSON.parse(btn.dataset.roles || "[]");
    const memberRoles = JSON.parse(btn.dataset.memberRoles || "[]");
    if (!this.menu)
      return;
    this.rolesDropdown = document.createElement("div");
    this.rolesDropdown.className = "absolute z-[70] w-52 bg-gray-900 rounded-lg shadow-2xl border border-gray-700 py-1.5 text-sm max-h-64 overflow-y-auto";
    const wrapper = btn.closest(".context-roles-wrapper");
    const menuRect = this.menu.getBoundingClientRect();
    const btnRect = wrapper.getBoundingClientRect();
    let ddLeft = btnRect.right + 4;
    if (ddLeft + 210 > window.innerWidth) {
      ddLeft = btnRect.left - 214;
    }
    let ddTop = btnRect.top;
    if (ddTop + 260 > window.innerHeight) {
      ddTop = window.innerHeight - 264;
    }
    this.rolesDropdown.style.position = "fixed";
    this.rolesDropdown.style.left = `${ddLeft}px`;
    this.rolesDropdown.style.top = `${ddTop}px`;
    let html = '<p class="px-3 py-1.5 text-[10px] font-semibold text-gray-500 uppercase sticky top-0 bg-gray-900">Assign Roles</p>';
    if (roles.length === 0) {
      html += '<p class="px-3 py-2 text-xs text-gray-500">No roles available</p>';
    } else {
      roles.forEach((role) => {
        const checked = memberRoles.includes(role.id) ? "checked" : "";
        const escapedName = this.escapeHtml(role.name);
        html += `<label class="flex items-center px-3 py-1.5 hover:bg-gray-800 cursor-pointer">
          <input type="checkbox" value="${role.id}" ${checked}
                 class="mr-2 accent-orange-500 context-role-checkbox">
          <span class="w-2.5 h-2.5 rounded-full mr-1.5 flex-shrink-0" style="background-color: ${role.color || "#ffffff"}"></span>
          <span class="text-gray-300 text-sm">${escapedName}</span>
        </label>`;
      });
    }
    this.rolesDropdown.innerHTML = html;
    document.body.appendChild(this.rolesDropdown);
    this.rolesDropdown.querySelectorAll(".context-role-checkbox").forEach((cb) => {
      cb.addEventListener("change", () => this.handleContextRoleToggle(memberId, serverId));
    });
    this.rolesDropdown.addEventListener("click", (e) => e.stopPropagation());
  }
  async handleContextRoleToggle(memberId, serverId) {
    if (!this.rolesDropdown)
      return;
    const checkboxes = this.rolesDropdown.querySelectorAll(".context-role-checkbox");
    const roleIds = Array.from(checkboxes).filter((cb) => cb.checked).map((cb) => cb.value);
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
      const response = await fetch(`/servers/${serverId}/settings/members/${memberId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ role_ids: roleIds })
      });
      if (!response.ok)
        throw new Error("Failed to update roles");
      this.showToast("Roles updated", "success");
    } catch (error2) {
      this.showToast("Failed to update roles", "error");
    }
  }
  changeNickname(event) {
    event.preventDefault();
    event.stopPropagation();
    const btn = event.currentTarget;
    const memberId = btn.dataset.memberId;
    const serverId = btn.dataset.serverId;
    const currentNickname = btn.dataset.currentNickname || "";
    this.closeMenu();
    this.nicknameModal = document.createElement("div");
    this.nicknameModal.className = "fixed inset-0 z-[100] flex items-center justify-center bg-black/60";
    this.nicknameModal.innerHTML = `
      <div class="bg-gray-800 rounded-lg shadow-2xl border border-gray-700 w-full max-w-sm mx-4 p-5" data-nickname-panel>
        <h3 class="text-lg font-bold text-white mb-1">Change Nickname</h3>
        <p class="text-xs text-gray-400 mb-4">Leave empty to reset to display name.</p>
        <input type="text" value="${this.escapeAttr(currentNickname)}" maxlength="32" placeholder="Enter nickname..."
               class="w-full bg-gray-900 border border-gray-600 rounded px-3 py-2 text-white text-sm focus:outline-none focus:border-orange-500 mb-4"
               data-nickname-input>
        <div class="flex justify-end gap-2">
          <button class="text-sm text-gray-400 hover:text-white px-4 py-1.5 rounded transition" data-nickname-cancel>Cancel</button>
          <button class="text-sm bg-orange-600 hover:bg-orange-700 text-white font-semibold px-4 py-1.5 rounded transition" data-nickname-save>Save</button>
        </div>
      </div>
    `;
    document.body.appendChild(this.nicknameModal);
    const input = this.nicknameModal.querySelector("[data-nickname-input]");
    input.focus();
    input.select();
    this.nicknameModal.addEventListener("click", (e) => {
      if (!e.target.closest("[data-nickname-panel]")) {
        this.closeNicknameModal();
      }
    });
    this.nicknameModal.querySelector("[data-nickname-cancel]").addEventListener("click", () => {
      this.closeNicknameModal();
    });
    this.nicknameModal.querySelector("[data-nickname-save]").addEventListener("click", () => {
      this.saveNickname(memberId, serverId, input.value.trim());
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        this.saveNickname(memberId, serverId, input.value.trim());
      }
      if (e.key === "Escape") {
        this.closeNicknameModal();
      }
    });
  }
  async saveNickname(memberId, serverId, nickname) {
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
      const response = await fetch(`/servers/${serverId}/settings/members/${memberId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ nickname: nickname || null })
      });
      if (!response.ok)
        throw new Error("Failed to update nickname");
      this.showToast("Nickname updated", "success");
      this.closeNicknameModal();
    } catch (error2) {
      this.showToast("Failed to update nickname", "error");
    }
  }
  closeNicknameModal() {
    if (this.nicknameModal) {
      this.nicknameModal.remove();
      this.nicknameModal = null;
    }
  }
  escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }
  escapeAttr(text) {
    return text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  showToast(message, type) {
    const toast = document.getElementById("toast");
    if (!toast)
      return;
    toast.textContent = message;
    toast.className = `fixed top-4 right-4 px-4 py-2 rounded-lg shadow-lg text-sm font-medium z-[100] transition-opacity duration-300 ${type === "success" ? "bg-green-600 text-white" : "bg-red-600 text-white"}`;
    toast.classList.remove("hidden", "opacity-0");
    setTimeout(() => {
      toast.classList.add("opacity-0");
      setTimeout(() => toast.classList.add("hidden"), 300);
    }, 3000);
  }
  closeMenu(event) {
    if (this.rolesDropdown) {
      if (event && this.rolesDropdown.contains(event.target))
        return;
      this.rolesDropdown.remove();
      this.rolesDropdown = null;
    }
    if (this.menu) {
      if (event && this.menu.contains(event.target))
        return;
      this.menu.remove();
      this.menu = null;
    }
    document.removeEventListener("click", this.boundClose);
  }
}

// app/javascript/controllers/category_collapse_controller.js
class category_collapse_controller_default extends Controller {
  static targets = ["arrow", "channels"];
  static values = { id: String };
  connect() {
    const collapsed = this.getCollapsed();
    if (collapsed.includes(this.idValue)) {
      this.collapse();
    }
  }
  toggle() {
    const isCollapsed = this.channelsTarget.classList.contains("hidden");
    if (isCollapsed) {
      this.expand();
      this.removeFromStorage();
    } else {
      this.collapse();
      this.addToStorage();
    }
  }
  collapse() {
    this.channelsTarget.classList.add("hidden");
    this.arrowTarget.classList.add("-rotate-90");
  }
  expand() {
    this.channelsTarget.classList.remove("hidden");
    this.arrowTarget.classList.remove("-rotate-90");
  }
  getCollapsed() {
    try {
      return JSON.parse(localStorage.getItem("collapsed_categories") || "[]");
    } catch {
      return [];
    }
  }
  addToStorage() {
    const collapsed = this.getCollapsed();
    if (!collapsed.includes(this.idValue)) {
      collapsed.push(this.idValue);
      localStorage.setItem("collapsed_categories", JSON.stringify(collapsed));
    }
  }
  removeFromStorage() {
    const collapsed = this.getCollapsed().filter((id) => id !== this.idValue);
    localStorage.setItem("collapsed_categories", JSON.stringify(collapsed));
  }
}

// app/javascript/controllers/channel_sidebar_controller.js
class channel_sidebar_controller_default extends Controller {
  static values = { serverId: String };
  connect() {
    this.subscription = createConsumer3().subscriptions.create({ channel: "ServerChannel", server_id: this.serverIdValue }, {
      received: (data) => this.handleMessage(data)
    });
    this._channelCache = new Map;
    this._onChannelClick = this._handleChannelClick.bind(this);
    this.element.addEventListener("click", this._onChannelClick, true);
    this._onBeforeFrameRender = (e) => {
      if (e.target.id !== "main-content")
        return;
      const frame = e.target;
      const currentId = this._getCurrentChannelId(frame);
      if (currentId && !this._channelCache.has(currentId)) {
        this._channelCache.set(currentId, frame.innerHTML);
        this._enforceCacheLimit();
      }
    };
    document.addEventListener("turbo:before-frame-render", this._onBeforeFrameRender);
  }
  disconnect() {
    if (this.subscription)
      this.subscription.unsubscribe();
    this.element.removeEventListener("click", this._onChannelClick, true);
    document.removeEventListener("turbo:before-frame-render", this._onBeforeFrameRender);
    this._channelCache.clear();
  }
  _getCurrentChannelId(frame) {
    const el = frame?.querySelector("[data-current-channel-id]");
    return el?.dataset.currentChannelId || null;
  }
  _enforceCacheLimit() {
    while (this._channelCache.size > 10) {
      const oldest = this._channelCache.keys().next().value;
      this._channelCache.delete(oldest);
    }
  }
  _handleChannelClick(e) {
    const link = e.target.closest("a[data-channel-id]");
    if (!link)
      return;
    const targetId = link.dataset.channelId;
    const frame = document.getElementById("main-content");
    const currentId = this._getCurrentChannelId(frame);
    if (targetId === currentId) {
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    if (this._channelCache.has(targetId)) {
      e.preventDefault();
      e.stopPropagation();
      if (currentId && frame) {
        this._channelCache.set(currentId, frame.innerHTML);
        this._enforceCacheLimit();
      }
      frame.innerHTML = this._channelCache.get(targetId);
      this._channelCache.delete(targetId);
      history.pushState({}, "", link.getAttribute("href"));
    }
    this._updateActiveChannel(link);
  }
  _updateActiveChannel(link) {
    const active = this.element.querySelector("a[data-channel-id].bg-gray-600");
    if (active && active !== link) {
      active.classList.remove("bg-gray-600");
      if (active.querySelector(".unread-pill") || active.querySelector(".font-bold")) {
        active.classList.add("hover:bg-gray-700");
      } else {
        active.classList.remove("text-white");
        active.classList.add("text-gray-400", "hover:bg-gray-700", "hover:text-gray-200");
      }
    }
    link.classList.remove("text-gray-400", "hover:bg-gray-700", "hover:text-gray-200");
    link.classList.add("bg-gray-600", "text-white");
    const pill = link.querySelector(".unread-pill");
    if (pill)
      pill.remove();
    const nameSpan = link.querySelector(".truncate");
    if (nameSpan)
      nameSpan.classList.remove("font-bold");
    const badge = link.querySelector(".mention-badge");
    if (badge)
      badge.remove();
  }
  handleMessage(data) {
    switch (data.type) {
      case "channel_created":
        this.addChannel(data);
        break;
      case "channel_updated":
        this.updateChannel(data);
        break;
      case "channel_deleted":
        this.removeChannel(data);
        break;
      case "category_created":
        this.addCategory(data);
        break;
      case "category_updated":
        this.updateCategory(data);
        break;
      case "category_deleted":
        this.removeCategory(data);
        break;
      case "sidebar_reorder":
        this.reorderSidebar(data);
        break;
    }
  }
  buildChannelHtml(data) {
    const serverId = this.serverIdValue;
    return `<a href="/servers/${serverId}/channels/${data.channel_id}"
               data-turbo-frame="main-content"
               data-channel-id="${data.channel_id}"
               class="flex items-center px-2 py-1.5 rounded group relative text-gray-400 hover:bg-gray-700 hover:text-gray-200">
              <span class="text-lg mr-1.5 opacity-60">#</span>
              <span class="truncate text-sm font-medium flex-1">${this.escapeHtml(data.name)}</span>
            </a>`;
  }
  addChannel(data) {
    if (this.element.querySelector(`[data-channel-id="${data.channel_id}"]`))
      return;
    const html = this.buildChannelHtml(data);
    if (data.category_id) {
      const categoryEl = this.element.querySelector(`[data-category-id="${data.category_id}"]`);
      if (categoryEl) {
        const channelsDiv = categoryEl.querySelector("[data-category-collapse-target='channels']");
        if (channelsDiv) {
          channelsDiv.insertAdjacentHTML("beforeend", html);
          return;
        }
      }
    }
    const firstCategory = this.element.querySelector("[data-category-id]");
    if (firstCategory) {
      firstCategory.insertAdjacentHTML("beforebegin", html);
    } else {
      this.element.insertAdjacentHTML("beforeend", html);
    }
  }
  updateChannel(data) {
    const existing = this.element.querySelector(`[data-channel-id="${data.channel_id}"]`);
    if (!existing)
      return;
    const nameSpan = existing.querySelector(".truncate");
    if (nameSpan && data.name)
      nameSpan.textContent = data.name;
  }
  removeChannel(data) {
    const el = this.element.querySelector(`[data-channel-id="${data.channel_id}"]`);
    if (el)
      el.remove();
  }
  buildCategoryHtml(data) {
    const serverId = this.serverIdValue;
    return `<div data-controller="category-collapse" data-category-collapse-id-value="${data.category_id}" data-category-id="${data.category_id}" class="mb-1">
              <div class="flex items-center justify-between px-2 pt-4 pb-1 cursor-pointer group"
                   data-action="click->category-collapse#toggle">
                <div class="flex items-center">
                  <svg data-category-collapse-target="arrow" class="w-3 h-3 text-gray-400 mr-0.5 transition-transform duration-200" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
                  </svg>
                  <span class="text-xs font-semibold text-gray-400 uppercase tracking-wide group-hover:text-gray-200">${this.escapeHtml(data.name)}</span>
                </div>
              </div>
              <div data-category-collapse-target="channels" class="space-y-0.5"></div>
            </div>`;
  }
  addCategory(data) {
    if (this.element.querySelector(`[data-category-id="${data.category_id}"]`))
      return;
    const html = this.buildCategoryHtml(data);
    this.element.insertAdjacentHTML("beforeend", html);
  }
  updateCategory(data) {
    const el = this.element.querySelector(`[data-category-id="${data.category_id}"]`);
    if (el && data.name) {
      const nameSpan = el.querySelector(".uppercase.tracking-wide");
      if (nameSpan)
        nameSpan.textContent = data.name;
    }
  }
  removeCategory(data) {
    const el = this.element.querySelector(`[data-category-id="${data.category_id}"]`);
    if (!el)
      return;
    const channels = el.querySelectorAll("[data-channel-id]");
    const firstCategory = this.element.querySelector("[data-category-id]");
    channels.forEach((ch) => {
      if (firstCategory && firstCategory !== el)
        firstCategory.before(ch);
      else
        this.element.prepend(ch);
    });
    el.remove();
  }
  reorderSidebar(data) {
    const { channels, categories } = data;
    if (categories?.length) {
      const sorted = [...categories].sort((a, b) => a.position - b.position);
      sorted.forEach((cat) => {
        const el = this.element.querySelector(`[data-category-id="${cat.id}"]`);
        if (el)
          this.element.appendChild(el);
      });
    }
    if (channels?.length) {
      const byCat = {};
      channels.forEach((ch) => {
        const key = ch.category_id || "__uncategorized__";
        if (!byCat[key])
          byCat[key] = [];
        byCat[key].push(ch);
      });
      Object.values(byCat).forEach((group) => group.sort((a, b) => a.position - b.position));
      if (byCat["__uncategorized__"]) {
        const firstCat = this.element.querySelector("[data-category-id]");
        byCat["__uncategorized__"].forEach((ch) => {
          const el = this.element.querySelector(`[data-channel-id="${ch.id}"]`);
          if (!el)
            return;
          if (firstCat)
            firstCat.before(el);
          else
            this.element.appendChild(el);
        });
      }
      Object.entries(byCat).forEach(([catId, group]) => {
        if (catId === "__uncategorized__")
          return;
        const catEl = this.element.querySelector(`[data-category-id="${catId}"]`);
        if (!catEl)
          return;
        const container = catEl.querySelector("[data-category-collapse-target='channels']");
        if (!container)
          return;
        group.forEach((ch) => {
          const el = this.element.querySelector(`[data-channel-id="${ch.id}"]`);
          if (el)
            container.appendChild(el);
        });
      });
    }
  }
  escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }
}

// node_modules/sortablejs/modular/sortable.esm.js
function _defineProperty(e, r, t) {
  return (r = _toPropertyKey(r)) in e ? Object.defineProperty(e, r, {
    value: t,
    enumerable: true,
    configurable: true,
    writable: true
  }) : e[r] = t, e;
}
function _extends() {
  return _extends = Object.assign ? Object.assign.bind() : function(n) {
    for (var e = 1;e < arguments.length; e++) {
      var t = arguments[e];
      for (var r in t)
        ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]);
    }
    return n;
  }, _extends.apply(null, arguments);
}
function ownKeys(e, r) {
  var t = Object.keys(e);
  if (Object.getOwnPropertySymbols) {
    var o = Object.getOwnPropertySymbols(e);
    r && (o = o.filter(function(r2) {
      return Object.getOwnPropertyDescriptor(e, r2).enumerable;
    })), t.push.apply(t, o);
  }
  return t;
}
function _objectSpread2(e) {
  for (var r = 1;r < arguments.length; r++) {
    var t = arguments[r] != null ? arguments[r] : {};
    r % 2 ? ownKeys(Object(t), true).forEach(function(r2) {
      _defineProperty(e, r2, t[r2]);
    }) : Object.getOwnPropertyDescriptors ? Object.defineProperties(e, Object.getOwnPropertyDescriptors(t)) : ownKeys(Object(t)).forEach(function(r2) {
      Object.defineProperty(e, r2, Object.getOwnPropertyDescriptor(t, r2));
    });
  }
  return e;
}
function _objectWithoutProperties(e, t) {
  if (e == null)
    return {};
  var o, r, i = _objectWithoutPropertiesLoose(e, t);
  if (Object.getOwnPropertySymbols) {
    var n = Object.getOwnPropertySymbols(e);
    for (r = 0;r < n.length; r++)
      o = n[r], t.indexOf(o) === -1 && {}.propertyIsEnumerable.call(e, o) && (i[o] = e[o]);
  }
  return i;
}
function _objectWithoutPropertiesLoose(r, e) {
  if (r == null)
    return {};
  var t = {};
  for (var n in r)
    if ({}.hasOwnProperty.call(r, n)) {
      if (e.indexOf(n) !== -1)
        continue;
      t[n] = r[n];
    }
  return t;
}
function _toPrimitive(t, r) {
  if (typeof t != "object" || !t)
    return t;
  var e = t[Symbol.toPrimitive];
  if (e !== undefined) {
    var i = e.call(t, r || "default");
    if (typeof i != "object")
      return i;
    throw new TypeError("@@toPrimitive must return a primitive value.");
  }
  return (r === "string" ? String : Number)(t);
}
function _toPropertyKey(t) {
  var i = _toPrimitive(t, "string");
  return typeof i == "symbol" ? i : i + "";
}
function _typeof(o) {
  "@babel/helpers - typeof";
  return _typeof = typeof Symbol == "function" && typeof Symbol.iterator == "symbol" ? function(o2) {
    return typeof o2;
  } : function(o2) {
    return o2 && typeof Symbol == "function" && o2.constructor === Symbol && o2 !== Symbol.prototype ? "symbol" : typeof o2;
  }, _typeof(o);
}
var version = "1.15.7";
function userAgent(pattern) {
  if (typeof window !== "undefined" && window.navigator) {
    return !!/* @__PURE__ */ navigator.userAgent.match(pattern);
  }
}
var IE11OrLess = userAgent(/(?:Trident.*rv[ :]?11\.|msie|iemobile|Windows Phone)/i);
var Edge = userAgent(/Edge/i);
var FireFox = userAgent(/firefox/i);
var Safari = userAgent(/safari/i) && !userAgent(/chrome/i) && !userAgent(/android/i);
var IOS = userAgent(/iP(ad|od|hone)/i);
var ChromeForAndroid = userAgent(/chrome/i) && userAgent(/android/i);
var captureMode = {
  capture: false,
  passive: false
};
function on(el, event, fn) {
  el.addEventListener(event, fn, !IE11OrLess && captureMode);
}
function off(el, event, fn) {
  el.removeEventListener(event, fn, !IE11OrLess && captureMode);
}
function matches(el, selector) {
  if (!selector)
    return;
  selector[0] === ">" && (selector = selector.substring(1));
  if (el) {
    try {
      if (el.matches) {
        return el.matches(selector);
      } else if (el.msMatchesSelector) {
        return el.msMatchesSelector(selector);
      } else if (el.webkitMatchesSelector) {
        return el.webkitMatchesSelector(selector);
      }
    } catch (_) {
      return false;
    }
  }
  return false;
}
function getParentOrHost(el) {
  return el.host && el !== document && el.host.nodeType && el.host !== el ? el.host : el.parentNode;
}
function closest(el, selector, ctx, includeCTX) {
  if (el) {
    ctx = ctx || document;
    do {
      if (selector != null && (selector[0] === ">" ? el.parentNode === ctx && matches(el, selector) : matches(el, selector)) || includeCTX && el === ctx) {
        return el;
      }
      if (el === ctx)
        break;
    } while (el = getParentOrHost(el));
  }
  return null;
}
var R_SPACE = /\s+/g;
function toggleClass(el, name, state) {
  if (el && name) {
    if (el.classList) {
      el.classList[state ? "add" : "remove"](name);
    } else {
      var className = (" " + el.className + " ").replace(R_SPACE, " ").replace(" " + name + " ", " ");
      el.className = (className + (state ? " " + name : "")).replace(R_SPACE, " ");
    }
  }
}
function css(el, prop, val) {
  var style = el && el.style;
  if (style) {
    if (val === undefined) {
      if (document.defaultView && document.defaultView.getComputedStyle) {
        val = document.defaultView.getComputedStyle(el, "");
      } else if (el.currentStyle) {
        val = el.currentStyle;
      }
      return prop === undefined ? val : val[prop];
    } else {
      if (!(prop in style) && prop.indexOf("webkit") === -1) {
        prop = "-webkit-" + prop;
      }
      style[prop] = val + (typeof val === "string" ? "" : "px");
    }
  }
}
function matrix(el, selfOnly) {
  var appliedTransforms = "";
  if (typeof el === "string") {
    appliedTransforms = el;
  } else {
    do {
      var transform = css(el, "transform");
      if (transform && transform !== "none") {
        appliedTransforms = transform + " " + appliedTransforms;
      }
    } while (!selfOnly && (el = el.parentNode));
  }
  var matrixFn = window.DOMMatrix || window.WebKitCSSMatrix || window.CSSMatrix || window.MSCSSMatrix;
  return matrixFn && new matrixFn(appliedTransforms);
}
function find(ctx, tagName, iterator) {
  if (ctx) {
    var list = ctx.getElementsByTagName(tagName), i = 0, n = list.length;
    if (iterator) {
      for (;i < n; i++) {
        iterator(list[i], i);
      }
    }
    return list;
  }
  return [];
}
function getWindowScrollingElement() {
  var scrollingElement = document.scrollingElement;
  if (scrollingElement) {
    return scrollingElement;
  } else {
    return document.documentElement;
  }
}
function getRect(el, relativeToContainingBlock, relativeToNonStaticParent, undoScale, container) {
  if (!el.getBoundingClientRect && el !== window)
    return;
  var elRect, top, left, bottom, right, height, width;
  if (el !== window && el.parentNode && el !== getWindowScrollingElement()) {
    elRect = el.getBoundingClientRect();
    top = elRect.top;
    left = elRect.left;
    bottom = elRect.bottom;
    right = elRect.right;
    height = elRect.height;
    width = elRect.width;
  } else {
    top = 0;
    left = 0;
    bottom = window.innerHeight;
    right = window.innerWidth;
    height = window.innerHeight;
    width = window.innerWidth;
  }
  if ((relativeToContainingBlock || relativeToNonStaticParent) && el !== window) {
    container = container || el.parentNode;
    if (!IE11OrLess) {
      do {
        if (container && container.getBoundingClientRect && (css(container, "transform") !== "none" || relativeToNonStaticParent && css(container, "position") !== "static")) {
          var containerRect = container.getBoundingClientRect();
          top -= containerRect.top + parseInt(css(container, "border-top-width"));
          left -= containerRect.left + parseInt(css(container, "border-left-width"));
          bottom = top + elRect.height;
          right = left + elRect.width;
          break;
        }
      } while (container = container.parentNode);
    }
  }
  if (undoScale && el !== window) {
    var elMatrix = matrix(container || el), scaleX = elMatrix && elMatrix.a, scaleY = elMatrix && elMatrix.d;
    if (elMatrix) {
      top /= scaleY;
      left /= scaleX;
      width /= scaleX;
      height /= scaleY;
      bottom = top + height;
      right = left + width;
    }
  }
  return {
    top,
    left,
    bottom,
    right,
    width,
    height
  };
}
function isScrolledPast(el, elSide, parentSide) {
  var parent = getParentAutoScrollElement(el, true), elSideVal = getRect(el)[elSide];
  while (parent) {
    var parentSideVal = getRect(parent)[parentSide], visible = undefined;
    if (parentSide === "top" || parentSide === "left") {
      visible = elSideVal >= parentSideVal;
    } else {
      visible = elSideVal <= parentSideVal;
    }
    if (!visible)
      return parent;
    if (parent === getWindowScrollingElement())
      break;
    parent = getParentAutoScrollElement(parent, false);
  }
  return false;
}
function getChild(el, childNum, options, includeDragEl) {
  var currentChild = 0, i = 0, children = el.children;
  while (i < children.length) {
    if (children[i].style.display !== "none" && children[i] !== Sortable.ghost && (includeDragEl || children[i] !== Sortable.dragged) && closest(children[i], options.draggable, el, false)) {
      if (currentChild === childNum) {
        return children[i];
      }
      currentChild++;
    }
    i++;
  }
  return null;
}
function lastChild(el, selector) {
  var last = el.lastElementChild;
  while (last && (last === Sortable.ghost || css(last, "display") === "none" || selector && !matches(last, selector))) {
    last = last.previousElementSibling;
  }
  return last || null;
}
function index(el, selector) {
  var index2 = 0;
  if (!el || !el.parentNode) {
    return -1;
  }
  while (el = el.previousElementSibling) {
    if (el.nodeName.toUpperCase() !== "TEMPLATE" && el !== Sortable.clone && (!selector || matches(el, selector))) {
      index2++;
    }
  }
  return index2;
}
function getRelativeScrollOffset(el) {
  var offsetLeft = 0, offsetTop = 0, winScroller = getWindowScrollingElement();
  if (el) {
    do {
      var elMatrix = matrix(el), scaleX = elMatrix.a, scaleY = elMatrix.d;
      offsetLeft += el.scrollLeft * scaleX;
      offsetTop += el.scrollTop * scaleY;
    } while (el !== winScroller && (el = el.parentNode));
  }
  return [offsetLeft, offsetTop];
}
function indexOfObject(arr, obj) {
  for (var i in arr) {
    if (!arr.hasOwnProperty(i))
      continue;
    for (var key in obj) {
      if (obj.hasOwnProperty(key) && obj[key] === arr[i][key])
        return Number(i);
    }
  }
  return -1;
}
function getParentAutoScrollElement(el, includeSelf) {
  if (!el || !el.getBoundingClientRect)
    return getWindowScrollingElement();
  var elem = el;
  var gotSelf = false;
  do {
    if (elem.clientWidth < elem.scrollWidth || elem.clientHeight < elem.scrollHeight) {
      var elemCSS = css(elem);
      if (elem.clientWidth < elem.scrollWidth && (elemCSS.overflowX == "auto" || elemCSS.overflowX == "scroll") || elem.clientHeight < elem.scrollHeight && (elemCSS.overflowY == "auto" || elemCSS.overflowY == "scroll")) {
        if (!elem.getBoundingClientRect || elem === document.body)
          return getWindowScrollingElement();
        if (gotSelf || includeSelf)
          return elem;
        gotSelf = true;
      }
    }
  } while (elem = elem.parentNode);
  return getWindowScrollingElement();
}
function extend4(dst, src) {
  if (dst && src) {
    for (var key in src) {
      if (src.hasOwnProperty(key)) {
        dst[key] = src[key];
      }
    }
  }
  return dst;
}
function isRectEqual(rect1, rect2) {
  return Math.round(rect1.top) === Math.round(rect2.top) && Math.round(rect1.left) === Math.round(rect2.left) && Math.round(rect1.height) === Math.round(rect2.height) && Math.round(rect1.width) === Math.round(rect2.width);
}
var _throttleTimeout;
function throttle(callback, ms) {
  return function() {
    if (!_throttleTimeout) {
      var args = arguments, _this = this;
      if (args.length === 1) {
        callback.call(_this, args[0]);
      } else {
        callback.apply(_this, args);
      }
      _throttleTimeout = setTimeout(function() {
        _throttleTimeout = undefined;
      }, ms);
    }
  };
}
function cancelThrottle() {
  clearTimeout(_throttleTimeout);
  _throttleTimeout = undefined;
}
function scrollBy(el, x, y) {
  el.scrollLeft += x;
  el.scrollTop += y;
}
function clone(el) {
  var Polymer = window.Polymer;
  var $ = window.jQuery || window.Zepto;
  if (Polymer && Polymer.dom) {
    return Polymer.dom(el).cloneNode(true);
  } else if ($) {
    return $(el).clone(true)[0];
  } else {
    return el.cloneNode(true);
  }
}
function getChildContainingRectFromElement(container, options, ghostEl) {
  var rect = {};
  Array.from(container.children).forEach(function(child) {
    var _rect$left, _rect$top, _rect$right, _rect$bottom;
    if (!closest(child, options.draggable, container, false) || child.animated || child === ghostEl)
      return;
    var childRect = getRect(child);
    rect.left = Math.min((_rect$left = rect.left) !== null && _rect$left !== undefined ? _rect$left : Infinity, childRect.left);
    rect.top = Math.min((_rect$top = rect.top) !== null && _rect$top !== undefined ? _rect$top : Infinity, childRect.top);
    rect.right = Math.max((_rect$right = rect.right) !== null && _rect$right !== undefined ? _rect$right : -Infinity, childRect.right);
    rect.bottom = Math.max((_rect$bottom = rect.bottom) !== null && _rect$bottom !== undefined ? _rect$bottom : -Infinity, childRect.bottom);
  });
  rect.width = rect.right - rect.left;
  rect.height = rect.bottom - rect.top;
  rect.x = rect.left;
  rect.y = rect.top;
  return rect;
}
var expando = "Sortable" + new Date().getTime();
function AnimationStateManager() {
  var animationStates = [], animationCallbackId;
  return {
    captureAnimationState: function captureAnimationState() {
      animationStates = [];
      if (!this.options.animation)
        return;
      var children = [].slice.call(this.el.children);
      children.forEach(function(child) {
        if (css(child, "display") === "none" || child === Sortable.ghost)
          return;
        animationStates.push({
          target: child,
          rect: getRect(child)
        });
        var fromRect = _objectSpread2({}, animationStates[animationStates.length - 1].rect);
        if (child.thisAnimationDuration) {
          var childMatrix = matrix(child, true);
          if (childMatrix) {
            fromRect.top -= childMatrix.f;
            fromRect.left -= childMatrix.e;
          }
        }
        child.fromRect = fromRect;
      });
    },
    addAnimationState: function addAnimationState(state) {
      animationStates.push(state);
    },
    removeAnimationState: function removeAnimationState(target) {
      animationStates.splice(indexOfObject(animationStates, {
        target
      }), 1);
    },
    animateAll: function animateAll(callback) {
      var _this = this;
      if (!this.options.animation) {
        clearTimeout(animationCallbackId);
        if (typeof callback === "function")
          callback();
        return;
      }
      var animating = false, animationTime = 0;
      animationStates.forEach(function(state) {
        var time = 0, target = state.target, fromRect = target.fromRect, toRect = getRect(target), prevFromRect = target.prevFromRect, prevToRect = target.prevToRect, animatingRect = state.rect, targetMatrix = matrix(target, true);
        if (targetMatrix) {
          toRect.top -= targetMatrix.f;
          toRect.left -= targetMatrix.e;
        }
        target.toRect = toRect;
        if (target.thisAnimationDuration) {
          if (isRectEqual(prevFromRect, toRect) && !isRectEqual(fromRect, toRect) && (animatingRect.top - toRect.top) / (animatingRect.left - toRect.left) === (fromRect.top - toRect.top) / (fromRect.left - toRect.left)) {
            time = calculateRealTime(animatingRect, prevFromRect, prevToRect, _this.options);
          }
        }
        if (!isRectEqual(toRect, fromRect)) {
          target.prevFromRect = fromRect;
          target.prevToRect = toRect;
          if (!time) {
            time = _this.options.animation;
          }
          _this.animate(target, animatingRect, toRect, time);
        }
        if (time) {
          animating = true;
          animationTime = Math.max(animationTime, time);
          clearTimeout(target.animationResetTimer);
          target.animationResetTimer = setTimeout(function() {
            target.animationTime = 0;
            target.prevFromRect = null;
            target.fromRect = null;
            target.prevToRect = null;
            target.thisAnimationDuration = null;
          }, time);
          target.thisAnimationDuration = time;
        }
      });
      clearTimeout(animationCallbackId);
      if (!animating) {
        if (typeof callback === "function")
          callback();
      } else {
        animationCallbackId = setTimeout(function() {
          if (typeof callback === "function")
            callback();
        }, animationTime);
      }
      animationStates = [];
    },
    animate: function animate(target, currentRect, toRect, duration) {
      if (duration) {
        css(target, "transition", "");
        css(target, "transform", "");
        var elMatrix = matrix(this.el), scaleX = elMatrix && elMatrix.a, scaleY = elMatrix && elMatrix.d, translateX = (currentRect.left - toRect.left) / (scaleX || 1), translateY = (currentRect.top - toRect.top) / (scaleY || 1);
        target.animatingX = !!translateX;
        target.animatingY = !!translateY;
        css(target, "transform", "translate3d(" + translateX + "px," + translateY + "px,0)");
        this.forRepaintDummy = repaint(target);
        css(target, "transition", "transform " + duration + "ms" + (this.options.easing ? " " + this.options.easing : ""));
        css(target, "transform", "translate3d(0,0,0)");
        typeof target.animated === "number" && clearTimeout(target.animated);
        target.animated = setTimeout(function() {
          css(target, "transition", "");
          css(target, "transform", "");
          target.animated = false;
          target.animatingX = false;
          target.animatingY = false;
        }, duration);
      }
    }
  };
}
function repaint(target) {
  return target.offsetWidth;
}
function calculateRealTime(animatingRect, fromRect, toRect, options) {
  return Math.sqrt(Math.pow(fromRect.top - animatingRect.top, 2) + Math.pow(fromRect.left - animatingRect.left, 2)) / Math.sqrt(Math.pow(fromRect.top - toRect.top, 2) + Math.pow(fromRect.left - toRect.left, 2)) * options.animation;
}
var plugins = [];
var defaults = {
  initializeByDefault: true
};
var PluginManager = {
  mount: function mount(plugin) {
    for (var option in defaults) {
      if (defaults.hasOwnProperty(option) && !(option in plugin)) {
        plugin[option] = defaults[option];
      }
    }
    plugins.forEach(function(p) {
      if (p.pluginName === plugin.pluginName) {
        throw "Sortable: Cannot mount plugin ".concat(plugin.pluginName, " more than once");
      }
    });
    plugins.push(plugin);
  },
  pluginEvent: function pluginEvent(eventName, sortable, evt) {
    var _this = this;
    this.eventCanceled = false;
    evt.cancel = function() {
      _this.eventCanceled = true;
    };
    var eventNameGlobal = eventName + "Global";
    plugins.forEach(function(plugin) {
      if (!sortable[plugin.pluginName])
        return;
      if (sortable[plugin.pluginName][eventNameGlobal]) {
        sortable[plugin.pluginName][eventNameGlobal](_objectSpread2({
          sortable
        }, evt));
      }
      if (sortable.options[plugin.pluginName] && sortable[plugin.pluginName][eventName]) {
        sortable[plugin.pluginName][eventName](_objectSpread2({
          sortable
        }, evt));
      }
    });
  },
  initializePlugins: function initializePlugins(sortable, el, defaults2, options) {
    plugins.forEach(function(plugin) {
      var pluginName = plugin.pluginName;
      if (!sortable.options[pluginName] && !plugin.initializeByDefault)
        return;
      var initialized = new plugin(sortable, el, sortable.options);
      initialized.sortable = sortable;
      initialized.options = sortable.options;
      sortable[pluginName] = initialized;
      _extends(defaults2, initialized.defaults);
    });
    for (var option in sortable.options) {
      if (!sortable.options.hasOwnProperty(option))
        continue;
      var modified = this.modifyOption(sortable, option, sortable.options[option]);
      if (typeof modified !== "undefined") {
        sortable.options[option] = modified;
      }
    }
  },
  getEventProperties: function getEventProperties(name, sortable) {
    var eventProperties = {};
    plugins.forEach(function(plugin) {
      if (typeof plugin.eventProperties !== "function")
        return;
      _extends(eventProperties, plugin.eventProperties.call(sortable[plugin.pluginName], name));
    });
    return eventProperties;
  },
  modifyOption: function modifyOption(sortable, name, value) {
    var modifiedValue;
    plugins.forEach(function(plugin) {
      if (!sortable[plugin.pluginName])
        return;
      if (plugin.optionListeners && typeof plugin.optionListeners[name] === "function") {
        modifiedValue = plugin.optionListeners[name].call(sortable[plugin.pluginName], value);
      }
    });
    return modifiedValue;
  }
};
function dispatchEvent(_ref) {
  var { sortable, rootEl, name, targetEl, cloneEl, toEl, fromEl, oldIndex, newIndex, oldDraggableIndex, newDraggableIndex, originalEvent, putSortable, extraEventProperties } = _ref;
  sortable = sortable || rootEl && rootEl[expando];
  if (!sortable)
    return;
  var evt, options = sortable.options, onName = "on" + name.charAt(0).toUpperCase() + name.substr(1);
  if (window.CustomEvent && !IE11OrLess && !Edge) {
    evt = new CustomEvent(name, {
      bubbles: true,
      cancelable: true
    });
  } else {
    evt = document.createEvent("Event");
    evt.initEvent(name, true, true);
  }
  evt.to = toEl || rootEl;
  evt.from = fromEl || rootEl;
  evt.item = targetEl || rootEl;
  evt.clone = cloneEl;
  evt.oldIndex = oldIndex;
  evt.newIndex = newIndex;
  evt.oldDraggableIndex = oldDraggableIndex;
  evt.newDraggableIndex = newDraggableIndex;
  evt.originalEvent = originalEvent;
  evt.pullMode = putSortable ? putSortable.lastPutMode : undefined;
  var allEventProperties = _objectSpread2(_objectSpread2({}, extraEventProperties), PluginManager.getEventProperties(name, sortable));
  for (var option in allEventProperties) {
    evt[option] = allEventProperties[option];
  }
  if (rootEl) {
    rootEl.dispatchEvent(evt);
  }
  if (options[onName]) {
    options[onName].call(sortable, evt);
  }
}
var _excluded = ["evt"];
var pluginEvent2 = function pluginEvent3(eventName, sortable) {
  var _ref = arguments.length > 2 && arguments[2] !== undefined ? arguments[2] : {}, originalEvent = _ref.evt, data = _objectWithoutProperties(_ref, _excluded);
  PluginManager.pluginEvent.bind(Sortable)(eventName, sortable, _objectSpread2({
    dragEl,
    parentEl,
    ghostEl,
    rootEl,
    nextEl,
    lastDownEl,
    cloneEl,
    cloneHidden,
    dragStarted: moved,
    putSortable,
    activeSortable: Sortable.active,
    originalEvent,
    oldIndex,
    oldDraggableIndex,
    newIndex,
    newDraggableIndex,
    hideGhostForTarget: _hideGhostForTarget,
    unhideGhostForTarget: _unhideGhostForTarget,
    cloneNowHidden: function cloneNowHidden() {
      cloneHidden = true;
    },
    cloneNowShown: function cloneNowShown() {
      cloneHidden = false;
    },
    dispatchSortableEvent: function dispatchSortableEvent(name) {
      _dispatchEvent({
        sortable,
        name,
        originalEvent
      });
    }
  }, data));
};
function _dispatchEvent(info) {
  dispatchEvent(_objectSpread2({
    putSortable,
    cloneEl,
    targetEl: dragEl,
    rootEl,
    oldIndex,
    oldDraggableIndex,
    newIndex,
    newDraggableIndex
  }, info));
}
var dragEl;
var parentEl;
var ghostEl;
var rootEl;
var nextEl;
var lastDownEl;
var cloneEl;
var cloneHidden;
var oldIndex;
var newIndex;
var oldDraggableIndex;
var newDraggableIndex;
var activeGroup;
var putSortable;
var awaitingDragStarted = false;
var ignoreNextClick = false;
var sortables = [];
var tapEvt;
var touchEvt;
var lastDx;
var lastDy;
var tapDistanceLeft;
var tapDistanceTop;
var moved;
var lastTarget;
var lastDirection;
var pastFirstInvertThresh = false;
var isCircumstantialInvert = false;
var targetMoveDistance;
var ghostRelativeParent;
var ghostRelativeParentInitialScroll = [];
var _silent = false;
var savedInputChecked = [];
var documentExists = typeof document !== "undefined";
var PositionGhostAbsolutely = IOS;
var CSSFloatProperty = Edge || IE11OrLess ? "cssFloat" : "float";
var supportDraggable = documentExists && !ChromeForAndroid && !IOS && "draggable" in document.createElement("div");
var supportCssPointerEvents = function() {
  if (!documentExists)
    return;
  if (IE11OrLess) {
    return false;
  }
  var el = document.createElement("x");
  el.style.cssText = "pointer-events:auto";
  return el.style.pointerEvents === "auto";
}();
var _detectDirection = function _detectDirection2(el, options) {
  var elCSS = css(el), elWidth = parseInt(elCSS.width) - parseInt(elCSS.paddingLeft) - parseInt(elCSS.paddingRight) - parseInt(elCSS.borderLeftWidth) - parseInt(elCSS.borderRightWidth), child1 = getChild(el, 0, options), child2 = getChild(el, 1, options), firstChildCSS = child1 && css(child1), secondChildCSS = child2 && css(child2), firstChildWidth = firstChildCSS && parseInt(firstChildCSS.marginLeft) + parseInt(firstChildCSS.marginRight) + getRect(child1).width, secondChildWidth = secondChildCSS && parseInt(secondChildCSS.marginLeft) + parseInt(secondChildCSS.marginRight) + getRect(child2).width;
  if (elCSS.display === "flex") {
    return elCSS.flexDirection === "column" || elCSS.flexDirection === "column-reverse" ? "vertical" : "horizontal";
  }
  if (elCSS.display === "grid") {
    return elCSS.gridTemplateColumns.split(" ").length <= 1 ? "vertical" : "horizontal";
  }
  if (child1 && firstChildCSS["float"] && firstChildCSS["float"] !== "none") {
    var touchingSideChild2 = firstChildCSS["float"] === "left" ? "left" : "right";
    return child2 && (secondChildCSS.clear === "both" || secondChildCSS.clear === touchingSideChild2) ? "vertical" : "horizontal";
  }
  return child1 && (firstChildCSS.display === "block" || firstChildCSS.display === "flex" || firstChildCSS.display === "table" || firstChildCSS.display === "grid" || firstChildWidth >= elWidth && elCSS[CSSFloatProperty] === "none" || child2 && elCSS[CSSFloatProperty] === "none" && firstChildWidth + secondChildWidth > elWidth) ? "vertical" : "horizontal";
};
var _dragElInRowColumn = function _dragElInRowColumn2(dragRect, targetRect, vertical) {
  var dragElS1Opp = vertical ? dragRect.left : dragRect.top, dragElS2Opp = vertical ? dragRect.right : dragRect.bottom, dragElOppLength = vertical ? dragRect.width : dragRect.height, targetS1Opp = vertical ? targetRect.left : targetRect.top, targetS2Opp = vertical ? targetRect.right : targetRect.bottom, targetOppLength = vertical ? targetRect.width : targetRect.height;
  return dragElS1Opp === targetS1Opp || dragElS2Opp === targetS2Opp || dragElS1Opp + dragElOppLength / 2 === targetS1Opp + targetOppLength / 2;
};
var _detectNearestEmptySortable = function _detectNearestEmptySortable2(x, y) {
  var ret;
  sortables.some(function(sortable) {
    var threshold = sortable[expando].options.emptyInsertThreshold;
    if (!threshold || lastChild(sortable))
      return;
    var rect = getRect(sortable), insideHorizontally = x >= rect.left - threshold && x <= rect.right + threshold, insideVertically = y >= rect.top - threshold && y <= rect.bottom + threshold;
    if (insideHorizontally && insideVertically) {
      return ret = sortable;
    }
  });
  return ret;
};
var _prepareGroup = function _prepareGroup2(options) {
  function toFn(value, pull) {
    return function(to, from, dragEl2, evt) {
      var sameGroup = to.options.group.name && from.options.group.name && to.options.group.name === from.options.group.name;
      if (value == null && (pull || sameGroup)) {
        return true;
      } else if (value == null || value === false) {
        return false;
      } else if (pull && value === "clone") {
        return value;
      } else if (typeof value === "function") {
        return toFn(value(to, from, dragEl2, evt), pull)(to, from, dragEl2, evt);
      } else {
        var otherGroup = (pull ? to : from).options.group.name;
        return value === true || typeof value === "string" && value === otherGroup || value.join && value.indexOf(otherGroup) > -1;
      }
    };
  }
  var group = {};
  var originalGroup = options.group;
  if (!originalGroup || _typeof(originalGroup) != "object") {
    originalGroup = {
      name: originalGroup
    };
  }
  group.name = originalGroup.name;
  group.checkPull = toFn(originalGroup.pull, true);
  group.checkPut = toFn(originalGroup.put);
  group.revertClone = originalGroup.revertClone;
  options.group = group;
};
var _hideGhostForTarget = function _hideGhostForTarget2() {
  if (!supportCssPointerEvents && ghostEl) {
    css(ghostEl, "display", "none");
  }
};
var _unhideGhostForTarget = function _unhideGhostForTarget2() {
  if (!supportCssPointerEvents && ghostEl) {
    css(ghostEl, "display", "");
  }
};
if (documentExists && !ChromeForAndroid) {
  document.addEventListener("click", function(evt) {
    if (ignoreNextClick) {
      evt.preventDefault();
      evt.stopPropagation && evt.stopPropagation();
      evt.stopImmediatePropagation && evt.stopImmediatePropagation();
      ignoreNextClick = false;
      return false;
    }
  }, true);
}
var nearestEmptyInsertDetectEvent = function nearestEmptyInsertDetectEvent2(evt) {
  if (dragEl) {
    evt = evt.touches ? evt.touches[0] : evt;
    var nearest = _detectNearestEmptySortable(evt.clientX, evt.clientY);
    if (nearest) {
      var event = {};
      for (var i in evt) {
        if (evt.hasOwnProperty(i)) {
          event[i] = evt[i];
        }
      }
      event.target = event.rootEl = nearest;
      event.preventDefault = undefined;
      event.stopPropagation = undefined;
      nearest[expando]._onDragOver(event);
    }
  }
};
var _checkOutsideTargetEl = function _checkOutsideTargetEl2(evt) {
  if (dragEl) {
    dragEl.parentNode[expando]._isOutsideThisEl(evt.target);
  }
};
function Sortable(el, options) {
  if (!(el && el.nodeType && el.nodeType === 1)) {
    throw "Sortable: `el` must be an HTMLElement, not ".concat({}.toString.call(el));
  }
  this.el = el;
  this.options = options = _extends({}, options);
  el[expando] = this;
  var defaults2 = {
    group: null,
    sort: true,
    disabled: false,
    store: null,
    handle: null,
    draggable: /^[uo]l$/i.test(el.nodeName) ? ">li" : ">*",
    swapThreshold: 1,
    invertSwap: false,
    invertedSwapThreshold: null,
    removeCloneOnHide: true,
    direction: function direction() {
      return _detectDirection(el, this.options);
    },
    ghostClass: "sortable-ghost",
    chosenClass: "sortable-chosen",
    dragClass: "sortable-drag",
    ignore: "a, img",
    filter: null,
    preventOnFilter: true,
    animation: 0,
    easing: null,
    setData: function setData(dataTransfer, dragEl2) {
      dataTransfer.setData("Text", dragEl2.textContent);
    },
    dropBubble: false,
    dragoverBubble: false,
    dataIdAttr: "data-id",
    delay: 0,
    delayOnTouchOnly: false,
    touchStartThreshold: (Number.parseInt ? Number : window).parseInt(window.devicePixelRatio, 10) || 1,
    forceFallback: false,
    fallbackClass: "sortable-fallback",
    fallbackOnBody: false,
    fallbackTolerance: 0,
    fallbackOffset: {
      x: 0,
      y: 0
    },
    supportPointer: Sortable.supportPointer !== false && "PointerEvent" in window && (!Safari || IOS),
    emptyInsertThreshold: 5
  };
  PluginManager.initializePlugins(this, el, defaults2);
  for (var name in defaults2) {
    !(name in options) && (options[name] = defaults2[name]);
  }
  _prepareGroup(options);
  for (var fn in this) {
    if (fn.charAt(0) === "_" && typeof this[fn] === "function") {
      this[fn] = this[fn].bind(this);
    }
  }
  this.nativeDraggable = options.forceFallback ? false : supportDraggable;
  if (this.nativeDraggable) {
    this.options.touchStartThreshold = 1;
  }
  if (options.supportPointer) {
    on(el, "pointerdown", this._onTapStart);
  } else {
    on(el, "mousedown", this._onTapStart);
    on(el, "touchstart", this._onTapStart);
  }
  if (this.nativeDraggable) {
    on(el, "dragover", this);
    on(el, "dragenter", this);
  }
  sortables.push(this.el);
  options.store && options.store.get && this.sort(options.store.get(this) || []);
  _extends(this, AnimationStateManager());
}
Sortable.prototype = {
  constructor: Sortable,
  _isOutsideThisEl: function _isOutsideThisEl(target) {
    if (!this.el.contains(target) && target !== this.el) {
      lastTarget = null;
    }
  },
  _getDirection: function _getDirection(evt, target) {
    return typeof this.options.direction === "function" ? this.options.direction.call(this, evt, target, dragEl) : this.options.direction;
  },
  _onTapStart: function _onTapStart(evt) {
    if (!evt.cancelable)
      return;
    var _this = this, el = this.el, options = this.options, preventOnFilter = options.preventOnFilter, type = evt.type, touch = evt.touches && evt.touches[0] || evt.pointerType && evt.pointerType === "touch" && evt, target = (touch || evt).target, originalTarget = evt.target.shadowRoot && (evt.path && evt.path[0] || evt.composedPath && evt.composedPath()[0]) || target, filter = options.filter;
    _saveInputCheckedState(el);
    if (dragEl) {
      return;
    }
    if (/mousedown|pointerdown/.test(type) && evt.button !== 0 || options.disabled) {
      return;
    }
    if (originalTarget.isContentEditable) {
      return;
    }
    if (!this.nativeDraggable && Safari && target && target.tagName.toUpperCase() === "SELECT") {
      return;
    }
    target = closest(target, options.draggable, el, false);
    if (target && target.animated) {
      return;
    }
    if (lastDownEl === target) {
      return;
    }
    oldIndex = index(target);
    oldDraggableIndex = index(target, options.draggable);
    if (typeof filter === "function") {
      if (filter.call(this, evt, target, this)) {
        _dispatchEvent({
          sortable: _this,
          rootEl: originalTarget,
          name: "filter",
          targetEl: target,
          toEl: el,
          fromEl: el
        });
        pluginEvent2("filter", _this, {
          evt
        });
        preventOnFilter && evt.preventDefault();
        return;
      }
    } else if (filter) {
      filter = filter.split(",").some(function(criteria) {
        criteria = closest(originalTarget, criteria.trim(), el, false);
        if (criteria) {
          _dispatchEvent({
            sortable: _this,
            rootEl: criteria,
            name: "filter",
            targetEl: target,
            fromEl: el,
            toEl: el
          });
          pluginEvent2("filter", _this, {
            evt
          });
          return true;
        }
      });
      if (filter) {
        preventOnFilter && evt.preventDefault();
        return;
      }
    }
    if (options.handle && !closest(originalTarget, options.handle, el, false)) {
      return;
    }
    this._prepareDragStart(evt, touch, target);
  },
  _prepareDragStart: function _prepareDragStart(evt, touch, target) {
    var _this = this, el = _this.el, options = _this.options, ownerDocument = el.ownerDocument, dragStartFn;
    if (target && !dragEl && target.parentNode === el) {
      var dragRect = getRect(target);
      rootEl = el;
      dragEl = target;
      parentEl = dragEl.parentNode;
      nextEl = dragEl.nextSibling;
      lastDownEl = target;
      activeGroup = options.group;
      Sortable.dragged = dragEl;
      tapEvt = {
        target: dragEl,
        clientX: (touch || evt).clientX,
        clientY: (touch || evt).clientY
      };
      tapDistanceLeft = tapEvt.clientX - dragRect.left;
      tapDistanceTop = tapEvt.clientY - dragRect.top;
      this._lastX = (touch || evt).clientX;
      this._lastY = (touch || evt).clientY;
      dragEl.style["will-change"] = "all";
      dragStartFn = function dragStartFn() {
        pluginEvent2("delayEnded", _this, {
          evt
        });
        if (Sortable.eventCanceled) {
          _this._onDrop();
          return;
        }
        _this._disableDelayedDragEvents();
        if (!FireFox && _this.nativeDraggable) {
          dragEl.draggable = true;
        }
        _this._triggerDragStart(evt, touch);
        _dispatchEvent({
          sortable: _this,
          name: "choose",
          originalEvent: evt
        });
        toggleClass(dragEl, options.chosenClass, true);
      };
      options.ignore.split(",").forEach(function(criteria) {
        find(dragEl, criteria.trim(), _disableDraggable);
      });
      on(ownerDocument, "dragover", nearestEmptyInsertDetectEvent);
      on(ownerDocument, "mousemove", nearestEmptyInsertDetectEvent);
      on(ownerDocument, "touchmove", nearestEmptyInsertDetectEvent);
      if (options.supportPointer) {
        on(ownerDocument, "pointerup", _this._onDrop);
        !this.nativeDraggable && on(ownerDocument, "pointercancel", _this._onDrop);
      } else {
        on(ownerDocument, "mouseup", _this._onDrop);
        on(ownerDocument, "touchend", _this._onDrop);
        on(ownerDocument, "touchcancel", _this._onDrop);
      }
      if (FireFox && this.nativeDraggable) {
        this.options.touchStartThreshold = 4;
        dragEl.draggable = true;
      }
      pluginEvent2("delayStart", this, {
        evt
      });
      if (options.delay && (!options.delayOnTouchOnly || touch) && (!this.nativeDraggable || !(Edge || IE11OrLess))) {
        if (Sortable.eventCanceled) {
          this._onDrop();
          return;
        }
        if (options.supportPointer) {
          on(ownerDocument, "pointerup", _this._disableDelayedDrag);
          on(ownerDocument, "pointercancel", _this._disableDelayedDrag);
        } else {
          on(ownerDocument, "mouseup", _this._disableDelayedDrag);
          on(ownerDocument, "touchend", _this._disableDelayedDrag);
          on(ownerDocument, "touchcancel", _this._disableDelayedDrag);
        }
        on(ownerDocument, "mousemove", _this._delayedDragTouchMoveHandler);
        on(ownerDocument, "touchmove", _this._delayedDragTouchMoveHandler);
        options.supportPointer && on(ownerDocument, "pointermove", _this._delayedDragTouchMoveHandler);
        _this._dragStartTimer = setTimeout(dragStartFn, options.delay);
      } else {
        dragStartFn();
      }
    }
  },
  _delayedDragTouchMoveHandler: function _delayedDragTouchMoveHandler(e) {
    var touch = e.touches ? e.touches[0] : e;
    if (Math.max(Math.abs(touch.clientX - this._lastX), Math.abs(touch.clientY - this._lastY)) >= Math.floor(this.options.touchStartThreshold / (this.nativeDraggable && window.devicePixelRatio || 1))) {
      this._disableDelayedDrag();
    }
  },
  _disableDelayedDrag: function _disableDelayedDrag() {
    dragEl && _disableDraggable(dragEl);
    clearTimeout(this._dragStartTimer);
    this._disableDelayedDragEvents();
  },
  _disableDelayedDragEvents: function _disableDelayedDragEvents() {
    var ownerDocument = this.el.ownerDocument;
    off(ownerDocument, "mouseup", this._disableDelayedDrag);
    off(ownerDocument, "touchend", this._disableDelayedDrag);
    off(ownerDocument, "touchcancel", this._disableDelayedDrag);
    off(ownerDocument, "pointerup", this._disableDelayedDrag);
    off(ownerDocument, "pointercancel", this._disableDelayedDrag);
    off(ownerDocument, "mousemove", this._delayedDragTouchMoveHandler);
    off(ownerDocument, "touchmove", this._delayedDragTouchMoveHandler);
    off(ownerDocument, "pointermove", this._delayedDragTouchMoveHandler);
  },
  _triggerDragStart: function _triggerDragStart(evt, touch) {
    touch = touch || evt.pointerType == "touch" && evt;
    if (!this.nativeDraggable || touch) {
      if (this.options.supportPointer) {
        on(document, "pointermove", this._onTouchMove);
      } else if (touch) {
        on(document, "touchmove", this._onTouchMove);
      } else {
        on(document, "mousemove", this._onTouchMove);
      }
    } else {
      on(dragEl, "dragend", this);
      on(rootEl, "dragstart", this._onDragStart);
    }
    try {
      if (document.selection) {
        _nextTick(function() {
          document.selection.empty();
        });
      } else {
        window.getSelection().removeAllRanges();
      }
    } catch (err) {
    }
  },
  _dragStarted: function _dragStarted(fallback, evt) {
    awaitingDragStarted = false;
    if (rootEl && dragEl) {
      pluginEvent2("dragStarted", this, {
        evt
      });
      if (this.nativeDraggable) {
        on(document, "dragover", _checkOutsideTargetEl);
      }
      var options = this.options;
      !fallback && toggleClass(dragEl, options.dragClass, false);
      toggleClass(dragEl, options.ghostClass, true);
      Sortable.active = this;
      fallback && this._appendGhost();
      _dispatchEvent({
        sortable: this,
        name: "start",
        originalEvent: evt
      });
    } else {
      this._nulling();
    }
  },
  _emulateDragOver: function _emulateDragOver() {
    if (touchEvt) {
      this._lastX = touchEvt.clientX;
      this._lastY = touchEvt.clientY;
      _hideGhostForTarget();
      var target = document.elementFromPoint(touchEvt.clientX, touchEvt.clientY);
      var parent = target;
      while (target && target.shadowRoot) {
        target = target.shadowRoot.elementFromPoint(touchEvt.clientX, touchEvt.clientY);
        if (target === parent)
          break;
        parent = target;
      }
      dragEl.parentNode[expando]._isOutsideThisEl(target);
      if (parent) {
        do {
          if (parent[expando]) {
            var inserted = undefined;
            inserted = parent[expando]._onDragOver({
              clientX: touchEvt.clientX,
              clientY: touchEvt.clientY,
              target,
              rootEl: parent
            });
            if (inserted && !this.options.dragoverBubble) {
              break;
            }
          }
          target = parent;
        } while (parent = getParentOrHost(parent));
      }
      _unhideGhostForTarget();
    }
  },
  _onTouchMove: function _onTouchMove(evt) {
    if (tapEvt) {
      var options = this.options, fallbackTolerance = options.fallbackTolerance, fallbackOffset = options.fallbackOffset, touch = evt.touches ? evt.touches[0] : evt, ghostMatrix = ghostEl && matrix(ghostEl, true), scaleX = ghostEl && ghostMatrix && ghostMatrix.a, scaleY = ghostEl && ghostMatrix && ghostMatrix.d, relativeScrollOffset = PositionGhostAbsolutely && ghostRelativeParent && getRelativeScrollOffset(ghostRelativeParent), dx = (touch.clientX - tapEvt.clientX + fallbackOffset.x) / (scaleX || 1) + (relativeScrollOffset ? relativeScrollOffset[0] - ghostRelativeParentInitialScroll[0] : 0) / (scaleX || 1), dy = (touch.clientY - tapEvt.clientY + fallbackOffset.y) / (scaleY || 1) + (relativeScrollOffset ? relativeScrollOffset[1] - ghostRelativeParentInitialScroll[1] : 0) / (scaleY || 1);
      if (!Sortable.active && !awaitingDragStarted) {
        if (fallbackTolerance && Math.max(Math.abs(touch.clientX - this._lastX), Math.abs(touch.clientY - this._lastY)) < fallbackTolerance) {
          return;
        }
        this._onDragStart(evt, true);
      }
      if (ghostEl) {
        if (ghostMatrix) {
          ghostMatrix.e += dx - (lastDx || 0);
          ghostMatrix.f += dy - (lastDy || 0);
        } else {
          ghostMatrix = {
            a: 1,
            b: 0,
            c: 0,
            d: 1,
            e: dx,
            f: dy
          };
        }
        var cssMatrix = "matrix(".concat(ghostMatrix.a, ",").concat(ghostMatrix.b, ",").concat(ghostMatrix.c, ",").concat(ghostMatrix.d, ",").concat(ghostMatrix.e, ",").concat(ghostMatrix.f, ")");
        css(ghostEl, "webkitTransform", cssMatrix);
        css(ghostEl, "mozTransform", cssMatrix);
        css(ghostEl, "msTransform", cssMatrix);
        css(ghostEl, "transform", cssMatrix);
        lastDx = dx;
        lastDy = dy;
        touchEvt = touch;
      }
      evt.cancelable && evt.preventDefault();
    }
  },
  _appendGhost: function _appendGhost() {
    if (!ghostEl) {
      var container = this.options.fallbackOnBody ? document.body : rootEl, rect = getRect(dragEl, true, PositionGhostAbsolutely, true, container), options = this.options;
      if (PositionGhostAbsolutely) {
        ghostRelativeParent = container;
        while (css(ghostRelativeParent, "position") === "static" && css(ghostRelativeParent, "transform") === "none" && ghostRelativeParent !== document) {
          ghostRelativeParent = ghostRelativeParent.parentNode;
        }
        if (ghostRelativeParent !== document.body && ghostRelativeParent !== document.documentElement) {
          if (ghostRelativeParent === document)
            ghostRelativeParent = getWindowScrollingElement();
          rect.top += ghostRelativeParent.scrollTop;
          rect.left += ghostRelativeParent.scrollLeft;
        } else {
          ghostRelativeParent = getWindowScrollingElement();
        }
        ghostRelativeParentInitialScroll = getRelativeScrollOffset(ghostRelativeParent);
      }
      ghostEl = dragEl.cloneNode(true);
      toggleClass(ghostEl, options.ghostClass, false);
      toggleClass(ghostEl, options.fallbackClass, true);
      toggleClass(ghostEl, options.dragClass, true);
      css(ghostEl, "transition", "");
      css(ghostEl, "transform", "");
      css(ghostEl, "box-sizing", "border-box");
      css(ghostEl, "margin", 0);
      css(ghostEl, "top", rect.top);
      css(ghostEl, "left", rect.left);
      css(ghostEl, "width", rect.width);
      css(ghostEl, "height", rect.height);
      css(ghostEl, "opacity", "0.8");
      css(ghostEl, "position", PositionGhostAbsolutely ? "absolute" : "fixed");
      css(ghostEl, "zIndex", "100000");
      css(ghostEl, "pointerEvents", "none");
      Sortable.ghost = ghostEl;
      container.appendChild(ghostEl);
      css(ghostEl, "transform-origin", tapDistanceLeft / parseInt(ghostEl.style.width) * 100 + "% " + tapDistanceTop / parseInt(ghostEl.style.height) * 100 + "%");
    }
  },
  _onDragStart: function _onDragStart(evt, fallback) {
    var _this = this;
    var dataTransfer = evt.dataTransfer;
    var options = _this.options;
    pluginEvent2("dragStart", this, {
      evt
    });
    if (Sortable.eventCanceled) {
      this._onDrop();
      return;
    }
    pluginEvent2("setupClone", this);
    if (!Sortable.eventCanceled) {
      cloneEl = clone(dragEl);
      cloneEl.removeAttribute("id");
      cloneEl.draggable = false;
      cloneEl.style["will-change"] = "";
      this._hideClone();
      toggleClass(cloneEl, this.options.chosenClass, false);
      Sortable.clone = cloneEl;
    }
    _this.cloneId = _nextTick(function() {
      pluginEvent2("clone", _this);
      if (Sortable.eventCanceled)
        return;
      if (!_this.options.removeCloneOnHide) {
        rootEl.insertBefore(cloneEl, dragEl);
      }
      _this._hideClone();
      _dispatchEvent({
        sortable: _this,
        name: "clone"
      });
    });
    !fallback && toggleClass(dragEl, options.dragClass, true);
    if (fallback) {
      ignoreNextClick = true;
      _this._loopId = setInterval(_this._emulateDragOver, 50);
    } else {
      off(document, "mouseup", _this._onDrop);
      off(document, "touchend", _this._onDrop);
      off(document, "touchcancel", _this._onDrop);
      if (dataTransfer) {
        dataTransfer.effectAllowed = "move";
        options.setData && options.setData.call(_this, dataTransfer, dragEl);
      }
      on(document, "drop", _this);
      css(dragEl, "transform", "translateZ(0)");
    }
    awaitingDragStarted = true;
    _this._dragStartId = _nextTick(_this._dragStarted.bind(_this, fallback, evt));
    on(document, "selectstart", _this);
    moved = true;
    window.getSelection().removeAllRanges();
    if (Safari) {
      css(document.body, "user-select", "none");
    }
  },
  _onDragOver: function _onDragOver(evt) {
    var el = this.el, target = evt.target, dragRect, targetRect, revert, options = this.options, group = options.group, activeSortable = Sortable.active, isOwner = activeGroup === group, canSort = options.sort, fromSortable = putSortable || activeSortable, vertical, _this = this, completedFired = false;
    if (_silent)
      return;
    function dragOverEvent(name, extra) {
      pluginEvent2(name, _this, _objectSpread2({
        evt,
        isOwner,
        axis: vertical ? "vertical" : "horizontal",
        revert,
        dragRect,
        targetRect,
        canSort,
        fromSortable,
        target,
        completed,
        onMove: function onMove(target2, after2) {
          return _onMove(rootEl, el, dragEl, dragRect, target2, getRect(target2), evt, after2);
        },
        changed
      }, extra));
    }
    function capture() {
      dragOverEvent("dragOverAnimationCapture");
      _this.captureAnimationState();
      if (_this !== fromSortable) {
        fromSortable.captureAnimationState();
      }
    }
    function completed(insertion) {
      dragOverEvent("dragOverCompleted", {
        insertion
      });
      if (insertion) {
        if (isOwner) {
          activeSortable._hideClone();
        } else {
          activeSortable._showClone(_this);
        }
        if (_this !== fromSortable) {
          toggleClass(dragEl, putSortable ? putSortable.options.ghostClass : activeSortable.options.ghostClass, false);
          toggleClass(dragEl, options.ghostClass, true);
        }
        if (putSortable !== _this && _this !== Sortable.active) {
          putSortable = _this;
        } else if (_this === Sortable.active && putSortable) {
          putSortable = null;
        }
        if (fromSortable === _this) {
          _this._ignoreWhileAnimating = target;
        }
        _this.animateAll(function() {
          dragOverEvent("dragOverAnimationComplete");
          _this._ignoreWhileAnimating = null;
        });
        if (_this !== fromSortable) {
          fromSortable.animateAll();
          fromSortable._ignoreWhileAnimating = null;
        }
      }
      if (target === dragEl && !dragEl.animated || target === el && !target.animated) {
        lastTarget = null;
      }
      if (!options.dragoverBubble && !evt.rootEl && target !== document) {
        dragEl.parentNode[expando]._isOutsideThisEl(evt.target);
        !insertion && nearestEmptyInsertDetectEvent(evt);
      }
      !options.dragoverBubble && evt.stopPropagation && evt.stopPropagation();
      return completedFired = true;
    }
    function changed() {
      newIndex = index(dragEl);
      newDraggableIndex = index(dragEl, options.draggable);
      _dispatchEvent({
        sortable: _this,
        name: "change",
        toEl: el,
        newIndex,
        newDraggableIndex,
        originalEvent: evt
      });
    }
    if (evt.preventDefault !== undefined) {
      evt.cancelable && evt.preventDefault();
    }
    target = closest(target, options.draggable, el, true);
    dragOverEvent("dragOver");
    if (Sortable.eventCanceled)
      return completedFired;
    if (dragEl.contains(evt.target) || target.animated && target.animatingX && target.animatingY || _this._ignoreWhileAnimating === target) {
      return completed(false);
    }
    ignoreNextClick = false;
    if (activeSortable && !options.disabled && (isOwner ? canSort || (revert = parentEl !== rootEl) : putSortable === this || (this.lastPutMode = activeGroup.checkPull(this, activeSortable, dragEl, evt)) && group.checkPut(this, activeSortable, dragEl, evt))) {
      vertical = this._getDirection(evt, target) === "vertical";
      dragRect = getRect(dragEl);
      dragOverEvent("dragOverValid");
      if (Sortable.eventCanceled)
        return completedFired;
      if (revert) {
        parentEl = rootEl;
        capture();
        this._hideClone();
        dragOverEvent("revert");
        if (!Sortable.eventCanceled) {
          if (nextEl) {
            rootEl.insertBefore(dragEl, nextEl);
          } else {
            rootEl.appendChild(dragEl);
          }
        }
        return completed(true);
      }
      var elLastChild = lastChild(el, options.draggable);
      if (!elLastChild || _ghostIsLast(evt, vertical, this) && !elLastChild.animated) {
        if (elLastChild === dragEl) {
          return completed(false);
        }
        if (elLastChild && el === evt.target) {
          target = elLastChild;
        }
        if (target) {
          targetRect = getRect(target);
        }
        if (_onMove(rootEl, el, dragEl, dragRect, target, targetRect, evt, !!target) !== false) {
          capture();
          if (elLastChild && elLastChild.nextSibling) {
            el.insertBefore(dragEl, elLastChild.nextSibling);
          } else {
            el.appendChild(dragEl);
          }
          parentEl = el;
          changed();
          return completed(true);
        }
      } else if (elLastChild && _ghostIsFirst(evt, vertical, this)) {
        var firstChild = getChild(el, 0, options, true);
        if (firstChild === dragEl) {
          return completed(false);
        }
        target = firstChild;
        targetRect = getRect(target);
        if (_onMove(rootEl, el, dragEl, dragRect, target, targetRect, evt, false) !== false) {
          capture();
          el.insertBefore(dragEl, firstChild);
          parentEl = el;
          changed();
          return completed(true);
        }
      } else if (target.parentNode === el) {
        targetRect = getRect(target);
        var direction = 0, targetBeforeFirstSwap, differentLevel = dragEl.parentNode !== el, differentRowCol = !_dragElInRowColumn(dragEl.animated && dragEl.toRect || dragRect, target.animated && target.toRect || targetRect, vertical), side1 = vertical ? "top" : "left", scrolledPastTop = isScrolledPast(target, "top", "top") || isScrolledPast(dragEl, "top", "top"), scrollBefore = scrolledPastTop ? scrolledPastTop.scrollTop : undefined;
        if (lastTarget !== target) {
          targetBeforeFirstSwap = targetRect[side1];
          pastFirstInvertThresh = false;
          isCircumstantialInvert = !differentRowCol && options.invertSwap || differentLevel;
        }
        direction = _getSwapDirection(evt, target, targetRect, vertical, differentRowCol ? 1 : options.swapThreshold, options.invertedSwapThreshold == null ? options.swapThreshold : options.invertedSwapThreshold, isCircumstantialInvert, lastTarget === target);
        var sibling;
        if (direction !== 0) {
          var dragIndex = index(dragEl);
          do {
            dragIndex -= direction;
            sibling = parentEl.children[dragIndex];
          } while (sibling && (css(sibling, "display") === "none" || sibling === ghostEl));
        }
        if (direction === 0 || sibling === target) {
          return completed(false);
        }
        lastTarget = target;
        lastDirection = direction;
        var nextSibling = target.nextElementSibling, after = false;
        after = direction === 1;
        var moveVector = _onMove(rootEl, el, dragEl, dragRect, target, targetRect, evt, after);
        if (moveVector !== false) {
          if (moveVector === 1 || moveVector === -1) {
            after = moveVector === 1;
          }
          _silent = true;
          setTimeout(_unsilent, 30);
          capture();
          if (after && !nextSibling) {
            el.appendChild(dragEl);
          } else {
            target.parentNode.insertBefore(dragEl, after ? nextSibling : target);
          }
          if (scrolledPastTop) {
            scrollBy(scrolledPastTop, 0, scrollBefore - scrolledPastTop.scrollTop);
          }
          parentEl = dragEl.parentNode;
          if (targetBeforeFirstSwap !== undefined && !isCircumstantialInvert) {
            targetMoveDistance = Math.abs(targetBeforeFirstSwap - getRect(target)[side1]);
          }
          changed();
          return completed(true);
        }
      }
      if (el.contains(dragEl)) {
        return completed(false);
      }
    }
    return false;
  },
  _ignoreWhileAnimating: null,
  _offMoveEvents: function _offMoveEvents() {
    off(document, "mousemove", this._onTouchMove);
    off(document, "touchmove", this._onTouchMove);
    off(document, "pointermove", this._onTouchMove);
    off(document, "dragover", nearestEmptyInsertDetectEvent);
    off(document, "mousemove", nearestEmptyInsertDetectEvent);
    off(document, "touchmove", nearestEmptyInsertDetectEvent);
  },
  _offUpEvents: function _offUpEvents() {
    var ownerDocument = this.el.ownerDocument;
    off(ownerDocument, "mouseup", this._onDrop);
    off(ownerDocument, "touchend", this._onDrop);
    off(ownerDocument, "pointerup", this._onDrop);
    off(ownerDocument, "pointercancel", this._onDrop);
    off(ownerDocument, "touchcancel", this._onDrop);
    off(document, "selectstart", this);
  },
  _onDrop: function _onDrop(evt) {
    var el = this.el, options = this.options;
    newIndex = index(dragEl);
    newDraggableIndex = index(dragEl, options.draggable);
    pluginEvent2("drop", this, {
      evt
    });
    parentEl = dragEl && dragEl.parentNode;
    newIndex = index(dragEl);
    newDraggableIndex = index(dragEl, options.draggable);
    if (Sortable.eventCanceled) {
      this._nulling();
      return;
    }
    awaitingDragStarted = false;
    isCircumstantialInvert = false;
    pastFirstInvertThresh = false;
    clearInterval(this._loopId);
    clearTimeout(this._dragStartTimer);
    _cancelNextTick(this.cloneId);
    _cancelNextTick(this._dragStartId);
    if (this.nativeDraggable) {
      off(document, "drop", this);
      off(el, "dragstart", this._onDragStart);
    }
    this._offMoveEvents();
    this._offUpEvents();
    if (Safari) {
      css(document.body, "user-select", "");
    }
    css(dragEl, "transform", "");
    if (evt) {
      if (moved) {
        evt.cancelable && evt.preventDefault();
        !options.dropBubble && evt.stopPropagation();
      }
      ghostEl && ghostEl.parentNode && ghostEl.parentNode.removeChild(ghostEl);
      if (rootEl === parentEl || putSortable && putSortable.lastPutMode !== "clone") {
        cloneEl && cloneEl.parentNode && cloneEl.parentNode.removeChild(cloneEl);
      }
      if (dragEl) {
        if (this.nativeDraggable) {
          off(dragEl, "dragend", this);
        }
        _disableDraggable(dragEl);
        dragEl.style["will-change"] = "";
        if (moved && !awaitingDragStarted) {
          toggleClass(dragEl, putSortable ? putSortable.options.ghostClass : this.options.ghostClass, false);
        }
        toggleClass(dragEl, this.options.chosenClass, false);
        _dispatchEvent({
          sortable: this,
          name: "unchoose",
          toEl: parentEl,
          newIndex: null,
          newDraggableIndex: null,
          originalEvent: evt
        });
        if (rootEl !== parentEl) {
          if (newIndex >= 0) {
            _dispatchEvent({
              rootEl: parentEl,
              name: "add",
              toEl: parentEl,
              fromEl: rootEl,
              originalEvent: evt
            });
            _dispatchEvent({
              sortable: this,
              name: "remove",
              toEl: parentEl,
              originalEvent: evt
            });
            _dispatchEvent({
              rootEl: parentEl,
              name: "sort",
              toEl: parentEl,
              fromEl: rootEl,
              originalEvent: evt
            });
            _dispatchEvent({
              sortable: this,
              name: "sort",
              toEl: parentEl,
              originalEvent: evt
            });
          }
          putSortable && putSortable.save();
        } else {
          if (newIndex !== oldIndex) {
            if (newIndex >= 0) {
              _dispatchEvent({
                sortable: this,
                name: "update",
                toEl: parentEl,
                originalEvent: evt
              });
              _dispatchEvent({
                sortable: this,
                name: "sort",
                toEl: parentEl,
                originalEvent: evt
              });
            }
          }
        }
        if (Sortable.active) {
          if (newIndex == null || newIndex === -1) {
            newIndex = oldIndex;
            newDraggableIndex = oldDraggableIndex;
          }
          _dispatchEvent({
            sortable: this,
            name: "end",
            toEl: parentEl,
            originalEvent: evt
          });
          this.save();
        }
      }
    }
    this._nulling();
  },
  _nulling: function _nulling() {
    pluginEvent2("nulling", this);
    rootEl = dragEl = parentEl = ghostEl = nextEl = cloneEl = lastDownEl = cloneHidden = tapEvt = touchEvt = moved = newIndex = newDraggableIndex = oldIndex = oldDraggableIndex = lastTarget = lastDirection = putSortable = activeGroup = Sortable.dragged = Sortable.ghost = Sortable.clone = Sortable.active = null;
    var el = this.el;
    savedInputChecked.forEach(function(checkEl) {
      if (el.contains(checkEl)) {
        checkEl.checked = true;
      }
    });
    savedInputChecked.length = lastDx = lastDy = 0;
  },
  handleEvent: function handleEvent(evt) {
    switch (evt.type) {
      case "drop":
      case "dragend":
        this._onDrop(evt);
        break;
      case "dragenter":
      case "dragover":
        if (dragEl) {
          this._onDragOver(evt);
          _globalDragOver(evt);
        }
        break;
      case "selectstart":
        evt.preventDefault();
        break;
    }
  },
  toArray: function toArray() {
    var order = [], el, children = this.el.children, i = 0, n = children.length, options = this.options;
    for (;i < n; i++) {
      el = children[i];
      if (closest(el, options.draggable, this.el, false)) {
        order.push(el.getAttribute(options.dataIdAttr) || _generateId(el));
      }
    }
    return order;
  },
  sort: function sort(order, useAnimation) {
    var items = {}, rootEl2 = this.el;
    this.toArray().forEach(function(id, i) {
      var el = rootEl2.children[i];
      if (closest(el, this.options.draggable, rootEl2, false)) {
        items[id] = el;
      }
    }, this);
    useAnimation && this.captureAnimationState();
    order.forEach(function(id) {
      if (items[id]) {
        rootEl2.removeChild(items[id]);
        rootEl2.appendChild(items[id]);
      }
    });
    useAnimation && this.animateAll();
  },
  save: function save() {
    var store = this.options.store;
    store && store.set && store.set(this);
  },
  closest: function closest$1(el, selector) {
    return closest(el, selector || this.options.draggable, this.el, false);
  },
  option: function option(name, value) {
    var options = this.options;
    if (value === undefined) {
      return options[name];
    } else {
      var modifiedValue = PluginManager.modifyOption(this, name, value);
      if (typeof modifiedValue !== "undefined") {
        options[name] = modifiedValue;
      } else {
        options[name] = value;
      }
      if (name === "group") {
        _prepareGroup(options);
      }
    }
  },
  destroy: function destroy() {
    pluginEvent2("destroy", this);
    var el = this.el;
    el[expando] = null;
    off(el, "mousedown", this._onTapStart);
    off(el, "touchstart", this._onTapStart);
    off(el, "pointerdown", this._onTapStart);
    if (this.nativeDraggable) {
      off(el, "dragover", this);
      off(el, "dragenter", this);
    }
    Array.prototype.forEach.call(el.querySelectorAll("[draggable]"), function(el2) {
      el2.removeAttribute("draggable");
    });
    this._onDrop();
    this._disableDelayedDragEvents();
    sortables.splice(sortables.indexOf(this.el), 1);
    this.el = el = null;
  },
  _hideClone: function _hideClone() {
    if (!cloneHidden) {
      pluginEvent2("hideClone", this);
      if (Sortable.eventCanceled)
        return;
      css(cloneEl, "display", "none");
      if (this.options.removeCloneOnHide && cloneEl.parentNode) {
        cloneEl.parentNode.removeChild(cloneEl);
      }
      cloneHidden = true;
    }
  },
  _showClone: function _showClone(putSortable2) {
    if (putSortable2.lastPutMode !== "clone") {
      this._hideClone();
      return;
    }
    if (cloneHidden) {
      pluginEvent2("showClone", this);
      if (Sortable.eventCanceled)
        return;
      if (dragEl.parentNode == rootEl && !this.options.group.revertClone) {
        rootEl.insertBefore(cloneEl, dragEl);
      } else if (nextEl) {
        rootEl.insertBefore(cloneEl, nextEl);
      } else {
        rootEl.appendChild(cloneEl);
      }
      if (this.options.group.revertClone) {
        this.animate(dragEl, cloneEl);
      }
      css(cloneEl, "display", "");
      cloneHidden = false;
    }
  }
};
function _globalDragOver(evt) {
  if (evt.dataTransfer) {
    evt.dataTransfer.dropEffect = "move";
  }
  evt.cancelable && evt.preventDefault();
}
function _onMove(fromEl, toEl, dragEl2, dragRect, targetEl, targetRect, originalEvent, willInsertAfter) {
  var evt, sortable = fromEl[expando], onMoveFn = sortable.options.onMove, retVal;
  if (window.CustomEvent && !IE11OrLess && !Edge) {
    evt = new CustomEvent("move", {
      bubbles: true,
      cancelable: true
    });
  } else {
    evt = document.createEvent("Event");
    evt.initEvent("move", true, true);
  }
  evt.to = toEl;
  evt.from = fromEl;
  evt.dragged = dragEl2;
  evt.draggedRect = dragRect;
  evt.related = targetEl || toEl;
  evt.relatedRect = targetRect || getRect(toEl);
  evt.willInsertAfter = willInsertAfter;
  evt.originalEvent = originalEvent;
  fromEl.dispatchEvent(evt);
  if (onMoveFn) {
    retVal = onMoveFn.call(sortable, evt, originalEvent);
  }
  return retVal;
}
function _disableDraggable(el) {
  el.draggable = false;
}
function _unsilent() {
  _silent = false;
}
function _ghostIsFirst(evt, vertical, sortable) {
  var firstElRect = getRect(getChild(sortable.el, 0, sortable.options, true));
  var childContainingRect = getChildContainingRectFromElement(sortable.el, sortable.options, ghostEl);
  var spacer = 10;
  return vertical ? evt.clientX < childContainingRect.left - spacer || evt.clientY < firstElRect.top && evt.clientX < firstElRect.right : evt.clientY < childContainingRect.top - spacer || evt.clientY < firstElRect.bottom && evt.clientX < firstElRect.left;
}
function _ghostIsLast(evt, vertical, sortable) {
  var lastElRect = getRect(lastChild(sortable.el, sortable.options.draggable));
  var childContainingRect = getChildContainingRectFromElement(sortable.el, sortable.options, ghostEl);
  var spacer = 10;
  return vertical ? evt.clientX > childContainingRect.right + spacer || evt.clientY > lastElRect.bottom && evt.clientX > lastElRect.left : evt.clientY > childContainingRect.bottom + spacer || evt.clientX > lastElRect.right && evt.clientY > lastElRect.top;
}
function _getSwapDirection(evt, target, targetRect, vertical, swapThreshold, invertedSwapThreshold, invertSwap, isLastTarget) {
  var mouseOnAxis = vertical ? evt.clientY : evt.clientX, targetLength = vertical ? targetRect.height : targetRect.width, targetS1 = vertical ? targetRect.top : targetRect.left, targetS2 = vertical ? targetRect.bottom : targetRect.right, invert = false;
  if (!invertSwap) {
    if (isLastTarget && targetMoveDistance < targetLength * swapThreshold) {
      if (!pastFirstInvertThresh && (lastDirection === 1 ? mouseOnAxis > targetS1 + targetLength * invertedSwapThreshold / 2 : mouseOnAxis < targetS2 - targetLength * invertedSwapThreshold / 2)) {
        pastFirstInvertThresh = true;
      }
      if (!pastFirstInvertThresh) {
        if (lastDirection === 1 ? mouseOnAxis < targetS1 + targetMoveDistance : mouseOnAxis > targetS2 - targetMoveDistance) {
          return -lastDirection;
        }
      } else {
        invert = true;
      }
    } else {
      if (mouseOnAxis > targetS1 + targetLength * (1 - swapThreshold) / 2 && mouseOnAxis < targetS2 - targetLength * (1 - swapThreshold) / 2) {
        return _getInsertDirection(target);
      }
    }
  }
  invert = invert || invertSwap;
  if (invert) {
    if (mouseOnAxis < targetS1 + targetLength * invertedSwapThreshold / 2 || mouseOnAxis > targetS2 - targetLength * invertedSwapThreshold / 2) {
      return mouseOnAxis > targetS1 + targetLength / 2 ? 1 : -1;
    }
  }
  return 0;
}
function _getInsertDirection(target) {
  if (index(dragEl) < index(target)) {
    return 1;
  } else {
    return -1;
  }
}
function _generateId(el) {
  var str = el.tagName + el.className + el.src + el.href + el.textContent, i = str.length, sum = 0;
  while (i--) {
    sum += str.charCodeAt(i);
  }
  return sum.toString(36);
}
function _saveInputCheckedState(root) {
  savedInputChecked.length = 0;
  var inputs = root.getElementsByTagName("input");
  var idx = inputs.length;
  while (idx--) {
    var el = inputs[idx];
    el.checked && savedInputChecked.push(el);
  }
}
function _nextTick(fn) {
  return setTimeout(fn, 0);
}
function _cancelNextTick(id) {
  return clearTimeout(id);
}
if (documentExists) {
  on(document, "touchmove", function(evt) {
    if ((Sortable.active || awaitingDragStarted) && evt.cancelable) {
      evt.preventDefault();
    }
  });
}
Sortable.utils = {
  on,
  off,
  css,
  find,
  is: function is(el, selector) {
    return !!closest(el, selector, el, false);
  },
  extend: extend4,
  throttle,
  closest,
  toggleClass,
  clone,
  index,
  nextTick: _nextTick,
  cancelNextTick: _cancelNextTick,
  detectDirection: _detectDirection,
  getChild,
  expando
};
Sortable.get = function(element) {
  return element[expando];
};
Sortable.mount = function() {
  for (var _len = arguments.length, plugins2 = new Array(_len), _key = 0;_key < _len; _key++) {
    plugins2[_key] = arguments[_key];
  }
  if (plugins2[0].constructor === Array)
    plugins2 = plugins2[0];
  plugins2.forEach(function(plugin) {
    if (!plugin.prototype || !plugin.prototype.constructor) {
      throw "Sortable: Mounted plugin must be a constructor function, not ".concat({}.toString.call(plugin));
    }
    if (plugin.utils)
      Sortable.utils = _objectSpread2(_objectSpread2({}, Sortable.utils), plugin.utils);
    PluginManager.mount(plugin);
  });
};
Sortable.create = function(el, options) {
  return new Sortable(el, options);
};
Sortable.version = version;
var autoScrolls = [];
var scrollEl;
var scrollRootEl;
var scrolling = false;
var lastAutoScrollX;
var lastAutoScrollY;
var touchEvt$1;
var pointerElemChangedInterval;
function AutoScrollPlugin() {
  function AutoScroll() {
    this.defaults = {
      scroll: true,
      forceAutoScrollFallback: false,
      scrollSensitivity: 30,
      scrollSpeed: 10,
      bubbleScroll: true
    };
    for (var fn in this) {
      if (fn.charAt(0) === "_" && typeof this[fn] === "function") {
        this[fn] = this[fn].bind(this);
      }
    }
  }
  AutoScroll.prototype = {
    dragStarted: function dragStarted(_ref) {
      var originalEvent = _ref.originalEvent;
      if (this.sortable.nativeDraggable) {
        on(document, "dragover", this._handleAutoScroll);
      } else {
        if (this.options.supportPointer) {
          on(document, "pointermove", this._handleFallbackAutoScroll);
        } else if (originalEvent.touches) {
          on(document, "touchmove", this._handleFallbackAutoScroll);
        } else {
          on(document, "mousemove", this._handleFallbackAutoScroll);
        }
      }
    },
    dragOverCompleted: function dragOverCompleted(_ref2) {
      var originalEvent = _ref2.originalEvent;
      if (!this.options.dragOverBubble && !originalEvent.rootEl) {
        this._handleAutoScroll(originalEvent);
      }
    },
    drop: function drop() {
      if (this.sortable.nativeDraggable) {
        off(document, "dragover", this._handleAutoScroll);
      } else {
        off(document, "pointermove", this._handleFallbackAutoScroll);
        off(document, "touchmove", this._handleFallbackAutoScroll);
        off(document, "mousemove", this._handleFallbackAutoScroll);
      }
      clearPointerElemChangedInterval();
      clearAutoScrolls();
      cancelThrottle();
    },
    nulling: function nulling() {
      touchEvt$1 = scrollRootEl = scrollEl = scrolling = pointerElemChangedInterval = lastAutoScrollX = lastAutoScrollY = null;
      autoScrolls.length = 0;
    },
    _handleFallbackAutoScroll: function _handleFallbackAutoScroll(evt) {
      this._handleAutoScroll(evt, true);
    },
    _handleAutoScroll: function _handleAutoScroll(evt, fallback) {
      var _this = this;
      var x = (evt.touches ? evt.touches[0] : evt).clientX, y = (evt.touches ? evt.touches[0] : evt).clientY, elem = document.elementFromPoint(x, y);
      touchEvt$1 = evt;
      if (fallback || this.options.forceAutoScrollFallback || Edge || IE11OrLess || Safari) {
        autoScroll(evt, this.options, elem, fallback);
        var ogElemScroller = getParentAutoScrollElement(elem, true);
        if (scrolling && (!pointerElemChangedInterval || x !== lastAutoScrollX || y !== lastAutoScrollY)) {
          pointerElemChangedInterval && clearPointerElemChangedInterval();
          pointerElemChangedInterval = setInterval(function() {
            var newElem = getParentAutoScrollElement(document.elementFromPoint(x, y), true);
            if (newElem !== ogElemScroller) {
              ogElemScroller = newElem;
              clearAutoScrolls();
            }
            autoScroll(evt, _this.options, newElem, fallback);
          }, 10);
          lastAutoScrollX = x;
          lastAutoScrollY = y;
        }
      } else {
        if (!this.options.bubbleScroll || getParentAutoScrollElement(elem, true) === getWindowScrollingElement()) {
          clearAutoScrolls();
          return;
        }
        autoScroll(evt, this.options, getParentAutoScrollElement(elem, false), false);
      }
    }
  };
  return _extends(AutoScroll, {
    pluginName: "scroll",
    initializeByDefault: true
  });
}
function clearAutoScrolls() {
  autoScrolls.forEach(function(autoScroll) {
    clearInterval(autoScroll.pid);
  });
  autoScrolls = [];
}
function clearPointerElemChangedInterval() {
  clearInterval(pointerElemChangedInterval);
}
var autoScroll = throttle(function(evt, options, rootEl2, isFallback) {
  if (!options.scroll)
    return;
  var x = (evt.touches ? evt.touches[0] : evt).clientX, y = (evt.touches ? evt.touches[0] : evt).clientY, sens = options.scrollSensitivity, speed = options.scrollSpeed, winScroller = getWindowScrollingElement();
  var scrollThisInstance = false, scrollCustomFn;
  if (scrollRootEl !== rootEl2) {
    scrollRootEl = rootEl2;
    clearAutoScrolls();
    scrollEl = options.scroll;
    scrollCustomFn = options.scrollFn;
    if (scrollEl === true) {
      scrollEl = getParentAutoScrollElement(rootEl2, true);
    }
  }
  var layersOut = 0;
  var currentParent = scrollEl;
  do {
    var el = currentParent, rect = getRect(el), top = rect.top, bottom = rect.bottom, left = rect.left, right = rect.right, width = rect.width, height = rect.height, canScrollX = undefined, canScrollY = undefined, scrollWidth = el.scrollWidth, scrollHeight = el.scrollHeight, elCSS = css(el), scrollPosX = el.scrollLeft, scrollPosY = el.scrollTop;
    if (el === winScroller) {
      canScrollX = width < scrollWidth && (elCSS.overflowX === "auto" || elCSS.overflowX === "scroll" || elCSS.overflowX === "visible");
      canScrollY = height < scrollHeight && (elCSS.overflowY === "auto" || elCSS.overflowY === "scroll" || elCSS.overflowY === "visible");
    } else {
      canScrollX = width < scrollWidth && (elCSS.overflowX === "auto" || elCSS.overflowX === "scroll");
      canScrollY = height < scrollHeight && (elCSS.overflowY === "auto" || elCSS.overflowY === "scroll");
    }
    var vx = canScrollX && (Math.abs(right - x) <= sens && scrollPosX + width < scrollWidth) - (Math.abs(left - x) <= sens && !!scrollPosX);
    var vy = canScrollY && (Math.abs(bottom - y) <= sens && scrollPosY + height < scrollHeight) - (Math.abs(top - y) <= sens && !!scrollPosY);
    if (!autoScrolls[layersOut]) {
      for (var i = 0;i <= layersOut; i++) {
        if (!autoScrolls[i]) {
          autoScrolls[i] = {};
        }
      }
    }
    if (autoScrolls[layersOut].vx != vx || autoScrolls[layersOut].vy != vy || autoScrolls[layersOut].el !== el) {
      autoScrolls[layersOut].el = el;
      autoScrolls[layersOut].vx = vx;
      autoScrolls[layersOut].vy = vy;
      clearInterval(autoScrolls[layersOut].pid);
      if (vx != 0 || vy != 0) {
        scrollThisInstance = true;
        autoScrolls[layersOut].pid = setInterval(function() {
          if (isFallback && this.layer === 0) {
            Sortable.active._onTouchMove(touchEvt$1);
          }
          var scrollOffsetY = autoScrolls[this.layer].vy ? autoScrolls[this.layer].vy * speed : 0;
          var scrollOffsetX = autoScrolls[this.layer].vx ? autoScrolls[this.layer].vx * speed : 0;
          if (typeof scrollCustomFn === "function") {
            if (scrollCustomFn.call(Sortable.dragged.parentNode[expando], scrollOffsetX, scrollOffsetY, evt, touchEvt$1, autoScrolls[this.layer].el) !== "continue") {
              return;
            }
          }
          scrollBy(autoScrolls[this.layer].el, scrollOffsetX, scrollOffsetY);
        }.bind({
          layer: layersOut
        }), 24);
      }
    }
    layersOut++;
  } while (options.bubbleScroll && currentParent !== winScroller && (currentParent = getParentAutoScrollElement(currentParent, false)));
  scrolling = scrollThisInstance;
}, 30);
var drop = function drop2(_ref) {
  var { originalEvent, putSortable: putSortable2, dragEl: dragEl2, activeSortable, dispatchSortableEvent, hideGhostForTarget, unhideGhostForTarget } = _ref;
  if (!originalEvent)
    return;
  var toSortable = putSortable2 || activeSortable;
  hideGhostForTarget();
  var touch = originalEvent.changedTouches && originalEvent.changedTouches.length ? originalEvent.changedTouches[0] : originalEvent;
  var target = document.elementFromPoint(touch.clientX, touch.clientY);
  unhideGhostForTarget();
  if (toSortable && !toSortable.el.contains(target)) {
    dispatchSortableEvent("spill");
    this.onSpill({
      dragEl: dragEl2,
      putSortable: putSortable2
    });
  }
};
function Revert() {
}
Revert.prototype = {
  startIndex: null,
  dragStart: function dragStart(_ref2) {
    var oldDraggableIndex2 = _ref2.oldDraggableIndex;
    this.startIndex = oldDraggableIndex2;
  },
  onSpill: function onSpill(_ref3) {
    var { dragEl: dragEl2, putSortable: putSortable2 } = _ref3;
    this.sortable.captureAnimationState();
    if (putSortable2) {
      putSortable2.captureAnimationState();
    }
    var nextSibling = getChild(this.sortable.el, this.startIndex, this.options);
    if (nextSibling) {
      this.sortable.el.insertBefore(dragEl2, nextSibling);
    } else {
      this.sortable.el.appendChild(dragEl2);
    }
    this.sortable.animateAll();
    if (putSortable2) {
      putSortable2.animateAll();
    }
  },
  drop
};
_extends(Revert, {
  pluginName: "revertOnSpill"
});
function Remove() {
}
Remove.prototype = {
  onSpill: function onSpill2(_ref4) {
    var { dragEl: dragEl2, putSortable: putSortable2 } = _ref4;
    var parentSortable = putSortable2 || this.sortable;
    parentSortable.captureAnimationState();
    dragEl2.parentNode && dragEl2.parentNode.removeChild(dragEl2);
    parentSortable.animateAll();
  },
  drop
};
_extends(Remove, {
  pluginName: "removeOnSpill"
});
Sortable.mount(new AutoScrollPlugin);
Sortable.mount(Remove, Revert);
var sortable_esm_default = Sortable;

// app/javascript/controllers/channel_reorder_controller.js
class channel_reorder_controller_default extends Controller {
  static values = { serverId: String, canManage: Boolean };
  connect() {
    if (!this.canManageValue)
      return;
    this.sortables = [];
    this.setup();
  }
  disconnect() {
    this.sortables.forEach((s) => s.destroy());
    this.sortables = [];
  }
  setup() {
    const opts = {
      group: "channels",
      animation: 150,
      ghostClass: "opacity-20",
      chosenClass: "bg-gray-600",
      dragClass: "shadow-lg",
      fallbackOnBody: true,
      swapThreshold: 0.65,
      onEnd: () => this.saveOrder()
    };
    this.sortables.push(sortable_esm_default.create(this.element, {
      ...opts,
      group: "channels",
      draggable: "[data-channel-id], [data-category-id]",
      onMove: (evt) => {
        if (evt.dragged.hasAttribute("data-category-id")) {
          return evt.to === this.element;
        }
        return true;
      }
    }));
    this.element.querySelectorAll("[data-category-collapse-target='channels']").forEach((container) => {
      this.sortables.push(sortable_esm_default.create(container, {
        ...opts,
        group: "channels",
        draggable: "[data-channel-id]"
      }));
    });
  }
  async saveOrder() {
    const channels = [];
    const categories = [];
    let catPos = 0;
    this.element.querySelectorAll("[data-category-id]").forEach((catEl) => {
      const catId = catEl.dataset.categoryId;
      categories.push({ id: catId, position: catPos++ });
      let chPos = 0;
      const channelsDiv = catEl.querySelector("[data-category-collapse-target='channels']");
      if (channelsDiv) {
        channelsDiv.querySelectorAll("[data-channel-id]").forEach((chEl) => {
          channels.push({ id: chEl.dataset.channelId, position: chPos++, category_id: catId });
        });
      }
    });
    let uncatPos = 0;
    Array.from(this.element.children).forEach((child) => {
      if (child.hasAttribute("data-channel-id")) {
        channels.push({ id: child.dataset.channelId, position: uncatPos++, category_id: null });
      }
    });
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    await fetch(`/servers/${this.serverIdValue}/reorder_channels`, {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
      body: JSON.stringify({ channels, categories })
    });
  }
}

// app/javascript/controllers/image_preview_controller.js
class image_preview_controller_default extends Controller {
  connect() {
    this.onClick = this.handleClick.bind(this);
    this.onContext = this.handleContext.bind(this);
    this.element.addEventListener("click", this.onClick);
    this.element.addEventListener("contextmenu", this.onContext);
    this.closeMenu = () => {
      const m = document.getElementById("image-context-menu");
      if (m)
        m.remove();
    };
    document.addEventListener("click", this.closeMenu);
  }
  disconnect() {
    this.element.removeEventListener("click", this.onClick);
    this.element.removeEventListener("contextmenu", this.onContext);
    document.removeEventListener("click", this.closeMenu);
    this.closeMenu();
  }
  handleClick(e) {
    const img = e.target.closest("img[data-preview-src]");
    if (!img)
      return;
    e.preventDefault();
    this.openLightbox(img.dataset.previewSrc, img.dataset.previewFilename);
  }
  handleContext(e) {
    const videoEl = e.target.closest("[data-video-src]");
    if (videoEl) {
      e.preventDefault();
      this.closeMenu();
      this.showVideoContextMenu(e.clientX, e.clientY, videoEl.dataset.videoSrc, videoEl.dataset.videoFilename);
      return;
    }
    const img = e.target.closest("img[data-preview-src]");
    if (!img)
      return;
    e.preventDefault();
    this.closeMenu();
    this.showContextMenu(e.clientX, e.clientY, img.dataset.previewSrc, img.dataset.previewFilename);
  }
  openLightbox(src, filename) {
    const overlay = document.createElement("div");
    overlay.id = "image-lightbox";
    overlay.className = "fixed inset-0 z-[200] bg-black/80 flex items-center justify-center";
    overlay.style.touchAction = "none";
    const container = document.createElement("div");
    container.className = "relative max-w-[90vw] max-h-[90vh] flex flex-col items-center";
    const imgWrap = document.createElement("div");
    imgWrap.style.cssText = "overflow:hidden;display:flex;align-items:center;justify-content:center;max-width:90vw;max-height:85vh;";
    const img = document.createElement("img");
    img.src = src;
    img.className = "max-w-[90vw] max-h-[85vh] object-contain rounded-lg shadow-2xl";
    img.style.cssText = "transform-origin:center center;transition:transform 0.2s ease;cursor:zoom-in;touch-action:none;";
    img.draggable = false;
    let scale = 1, tx = 0, ty = 0;
    let pinchStartDist = 0, pinchStartScale = 1;
    let lastTap = 0;
    let isPanning = false, panStartX = 0, panStartY = 0, panStartTx = 0, panStartTy = 0;
    const applyTransform = (animate) => {
      img.style.transition = animate ? "transform 0.2s ease" : "none";
      img.style.transform = `translate(${tx}px,${ty}px) scale(${scale})`;
      img.style.cursor = scale > 1 ? "grab" : "zoom-in";
    };
    const clampPan = () => {
      if (scale <= 1) {
        tx = 0;
        ty = 0;
        return;
      }
      const rect = imgWrap.getBoundingClientRect();
      const imgW = img.naturalWidth ? Math.min(img.naturalWidth, rect.width) : rect.width;
      const imgH = img.naturalHeight ? Math.min(img.naturalHeight, rect.height) : rect.height;
      const maxTx = Math.max(0, (imgW * scale - rect.width) / 2);
      const maxTy = Math.max(0, (imgH * scale - rect.height) / 2);
      tx = Math.max(-maxTx, Math.min(maxTx, tx));
      ty = Math.max(-maxTy, Math.min(maxTy, ty));
    };
    const resetZoom = () => {
      scale = 1;
      tx = 0;
      ty = 0;
      applyTransform(true);
    };
    let isTouch = false;
    const toggleZoom = (clientX, clientY) => {
      if (scale > 1) {
        resetZoom();
      } else {
        const rect = img.getBoundingClientRect();
        const ox = clientX - (rect.left + rect.width / 2);
        const oy = clientY - (rect.top + rect.height / 2);
        scale = 3;
        tx = -ox * (scale - 1);
        ty = -oy * (scale - 1);
        clampPan();
        applyTransform(true);
      }
    };
    let mouseDidDrag = false;
    let mouseIsDown = false;
    let mousePanStartX = 0, mousePanStartY = 0, mousePanStartTx = 0, mousePanStartTy = 0;
    img.addEventListener("mousedown", (e) => {
      if (isTouch || e.button !== 0)
        return;
      mouseIsDown = true;
      mouseDidDrag = false;
      if (scale > 1) {
        mousePanStartX = e.clientX;
        mousePanStartY = e.clientY;
        mousePanStartTx = tx;
        mousePanStartTy = ty;
        img.style.cursor = "grabbing";
        e.preventDefault();
      }
    });
    document.addEventListener("mousemove", (e) => {
      if (!mouseIsDown || isTouch)
        return;
      if (scale > 1) {
        const dx = e.clientX - mousePanStartX;
        const dy = e.clientY - mousePanStartY;
        if (Math.abs(dx) > 3 || Math.abs(dy) > 3)
          mouseDidDrag = true;
        tx = mousePanStartTx + dx;
        ty = mousePanStartTy + dy;
        clampPan();
        applyTransform(false);
      }
    });
    document.addEventListener("mouseup", () => {
      if (mouseIsDown && scale > 1)
        img.style.cursor = "grab";
      mouseIsDown = false;
    });
    let touchDidPan = false;
    img.addEventListener("click", (e) => {
      if (isTouch)
        return;
      e.stopPropagation();
      if (mouseDidDrag) {
        mouseDidDrag = false;
        return;
      }
      toggleZoom(e.clientX, e.clientY);
    });
    img.addEventListener("touchstart", (e) => {
      isTouch = true;
      touchDidPan = false;
      if (e.touches.length === 1) {
        const now3 = Date.now();
        if (now3 - lastTap < 300) {
          e.preventDefault();
          toggleZoom(e.touches[0].clientX, e.touches[0].clientY);
          lastTap = 0;
          return;
        }
        lastTap = now3;
        if (scale > 1) {
          isPanning = true;
          panStartX = e.touches[0].clientX;
          panStartY = e.touches[0].clientY;
          panStartTx = tx;
          panStartTy = ty;
          img.style.cursor = "grabbing";
        }
      } else if (e.touches.length === 2) {
        e.preventDefault();
        isPanning = false;
        const d = Math.hypot(e.touches[1].clientX - e.touches[0].clientX, e.touches[1].clientY - e.touches[0].clientY);
        pinchStartDist = d;
        pinchStartScale = scale;
      }
    }, { passive: false });
    img.addEventListener("touchmove", (e) => {
      if (e.touches.length === 2) {
        e.preventDefault();
        touchDidPan = true;
        const d = Math.hypot(e.touches[1].clientX - e.touches[0].clientX, e.touches[1].clientY - e.touches[0].clientY);
        scale = Math.max(1, Math.min(8, pinchStartScale * (d / pinchStartDist)));
        clampPan();
        applyTransform(false);
      } else if (e.touches.length === 1 && isPanning) {
        e.preventDefault();
        touchDidPan = true;
        tx = panStartTx + (e.touches[0].clientX - panStartX);
        ty = panStartTy + (e.touches[0].clientY - panStartY);
        clampPan();
        applyTransform(false);
      }
    }, { passive: false });
    img.addEventListener("touchend", (e) => {
      isPanning = false;
      if (scale <= 1)
        resetZoom();
    });
    imgWrap.addEventListener("wheel", (e) => {
      e.preventDefault();
      const delta = e.deltaY > 0 ? 0.8 : 1.25;
      scale = Math.max(1, Math.min(8, scale * delta));
      if (scale <= 1) {
        resetZoom();
        return;
      }
      clampPan();
      applyTransform(false);
    }, { passive: false });
    overlay.addEventListener("click", (e) => {
      if (mouseDidDrag || touchDidPan) {
        mouseDidDrag = false;
        touchDidPan = false;
        return;
      }
      if (e.target === overlay) {
        cleanup();
        overlay.remove();
      }
    });
    const bar = document.createElement("div");
    bar.className = "flex items-center gap-3 mt-3";
    if (filename) {
      const name = document.createElement("span");
      name.className = "text-sm text-gray-300";
      name.textContent = filename;
      bar.appendChild(name);
    }
    const downloadBtn = document.createElement("a");
    downloadBtn.href = src;
    downloadBtn.download = filename || "image";
    downloadBtn.className = "text-sm text-blue-400 hover:text-blue-300 flex items-center gap-1";
    downloadBtn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg> Download';
    bar.appendChild(downloadBtn);
    const closeBtn = document.createElement("button");
    closeBtn.className = "absolute -top-2 -right-2 w-8 h-8 bg-gray-800 rounded-full flex items-center justify-center text-gray-400 hover:text-white border border-gray-600 cursor-pointer z-10";
    closeBtn.innerHTML = '<svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/></svg>';
    closeBtn.addEventListener("click", () => {
      cleanup();
      overlay.remove();
    });
    imgWrap.appendChild(img);
    container.appendChild(closeBtn);
    container.appendChild(imgWrap);
    container.appendChild(bar);
    overlay.appendChild(container);
    document.body.appendChild(overlay);
    const escHandler = (e) => {
      if (e.key === "Escape") {
        cleanup();
        overlay.remove();
      }
    };
    const cleanup = () => document.removeEventListener("keydown", escHandler);
    document.addEventListener("keydown", escHandler);
  }
  showContextMenu(x, y, src, filename) {
    const menu = document.createElement("div");
    menu.id = "image-context-menu";
    menu.className = "fixed z-[100] bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1.5 px-1.5 min-w-[180px]";
    menu.style.left = `${x}px`;
    menu.style.top = `${y}px`;
    const items = [
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>',
        label: "Copy Image",
        action: async () => {
          try {
            const res = await fetch(src);
            const blob = await res.blob();
            await navigator.clipboard.write([
              new ClipboardItem({ [blob.type]: blob })
            ]);
          } catch (err) {
            navigator.clipboard.writeText(src);
          }
        }
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/></svg>',
        label: "Copy Image Link",
        action: () => navigator.clipboard.writeText(src)
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>',
        label: "Save Image",
        action: () => {
          const a = document.createElement("a");
          a.href = src;
          a.download = filename || "image";
          a.click();
        }
      }
    ];
    items.forEach((item) => {
      const btn = document.createElement("button");
      btn.className = "flex items-center w-full px-2.5 py-1.5 text-sm text-gray-300 hover:bg-gray-700 hover:text-white rounded cursor-pointer";
      btn.innerHTML = `${item.icon}${item.label}`;
      btn.addEventListener("click", () => {
        item.action();
        menu.remove();
      });
      menu.appendChild(btn);
    });
    document.body.appendChild(menu);
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth)
      menu.style.left = `${window.innerWidth - rect.width - 8}px`;
    if (rect.bottom > window.innerHeight)
      menu.style.top = `${window.innerHeight - rect.height - 8}px`;
  }
  showVideoContextMenu(x, y, src, filename) {
    const menu = document.createElement("div");
    menu.id = "image-context-menu";
    menu.className = "fixed z-[100] bg-gray-900 border border-gray-700 rounded-lg shadow-xl py-1.5 px-1.5 min-w-[180px]";
    menu.style.left = `${x}px`;
    menu.style.top = `${y}px`;
    const items = [
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"/></svg>',
        label: "Copy Media Link",
        action: () => navigator.clipboard.writeText(src)
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>',
        label: "Save Video",
        action: () => {
          const a = document.createElement("a");
          a.href = src;
          a.download = filename || "video";
          a.click();
        }
      },
      {
        icon: '<svg class="w-4 h-4 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/></svg>',
        label: "Open in New Tab",
        action: () => window.open(src, "_blank")
      }
    ];
    items.forEach((item) => {
      const btn = document.createElement("button");
      btn.className = "flex items-center w-full px-2.5 py-1.5 text-sm text-gray-300 hover:bg-gray-700 hover:text-white rounded cursor-pointer";
      btn.innerHTML = `${item.icon}${item.label}`;
      btn.addEventListener("click", () => {
        item.action();
        menu.remove();
      });
      menu.appendChild(btn);
    });
    document.body.appendChild(menu);
    const rect = menu.getBoundingClientRect();
    if (rect.right > window.innerWidth)
      menu.style.left = `${window.innerWidth - rect.width - 8}px`;
    if (rect.bottom > window.innerHeight)
      menu.style.top = `${window.innerHeight - rect.height - 8}px`;
  }
}

// app/javascript/controllers/mobile_nav_controller.js
class mobile_nav_controller_default extends Controller {
  static targets = ["serverRail", "channelSidebar", "memberSidebar", "backdrop"];
  connect() {
    this.sidebarOpen = false;
    this.membersOpen = false;
    this._onFrameRender = () => {
      if (this.sidebarOpen || this.membersOpen)
        this.closeAll();
    };
    document.addEventListener("turbo:before-frame-render", this._onFrameRender);
  }
  disconnect() {
    document.removeEventListener("turbo:before-frame-render", this._onFrameRender);
  }
  toggleSidebar() {
    this.sidebarOpen = !this.sidebarOpen;
    this._updateSidebar();
  }
  toggleMembers() {
    this.membersOpen = !this.membersOpen;
    this._updateMembers();
  }
  closeAll() {
    this.sidebarOpen = false;
    this.membersOpen = false;
    this._updateSidebar();
    this._updateMembers();
  }
  _updateSidebar() {
    if (this.hasServerRailTarget) {
      this.serverRailTarget.classList.toggle("mobile-sidebar-open", this.sidebarOpen);
    }
    if (this.hasChannelSidebarTarget) {
      this.channelSidebarTarget.classList.toggle("mobile-sidebar-open", this.sidebarOpen);
    }
    if (this.hasBackdropTarget) {
      this.backdropTarget.classList.toggle("hidden", !this.sidebarOpen && !this.membersOpen);
    }
    document.body.classList.toggle("overflow-hidden", this.sidebarOpen || this.membersOpen);
  }
  _updateMembers() {
    if (this.hasMemberSidebarTarget) {
      this.memberSidebarTarget.classList.toggle("mobile-members-open", this.membersOpen);
    }
    if (this.hasBackdropTarget) {
      this.backdropTarget.classList.toggle("hidden", !this.sidebarOpen && !this.membersOpen);
    }
    document.body.classList.toggle("overflow-hidden", this.sidebarOpen || this.membersOpen);
  }
}

// app/javascript/controllers/banner_editor_controller.js
class banner_editor_controller_default extends Controller {
  static targets = [
    "container",
    "image",
    "hint",
    "offsetField",
    "input",
    "avatarPreview",
    "avatarInput",
    "avatarInitial",
    "previewBanner",
    "previewAvatar",
    "previewAvatarInitial",
    "previewGradient",
    "previewRing",
    "previewCard",
    "gradientPreviewStrip"
  ];
  connect() {
    console.log("[banner-editor] connected");
    this.dragging = false;
    this.startY = 0;
    this.startOffset = 0;
    this._onMouseMove = this.onDrag.bind(this);
    this._onMouseUp = this.stopDrag.bind(this);
    this.cropMode = null;
    this.cropScale = 1;
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    this.cropDragging = false;
    this.cropDataUrl = null;
    this.modal = null;
    this.cropImg = null;
    this.cropViewport = null;
  }
  openCropModal(mode, file) {
    this.cropMode = mode;
    this.cropScale = 1;
    this.cropOffsetX = 0;
    this.cropOffsetY = 0;
    if (this.modal)
      this.modal.remove();
    const reader = new FileReader;
    reader.onload = (ev) => {
      this.cropDataUrl = ev.target.result;
      this.buildAndShowModal(mode, ev.target.result);
    };
    reader.readAsDataURL(file);
  }
  buildAndShowModal(mode, src) {
    const vpHeight = mode === "avatar" ? 300 : 180;
    const title = mode === "avatar" ? "Edit Avatar" : "Edit Banner";
    this.modal = document.createElement("div");
    this.modal.className = "fixed inset-0 z-[300] flex items-center justify-center bg-black/70";
    this.modal.innerHTML = `
      <div class="bg-gray-800 rounded-xl shadow-2xl w-full max-w-lg mx-4">
        <div class="px-5 pt-5 pb-3">
          <h3 class="text-white text-lg font-semibold">${title}</h3>
          <p class="text-gray-400 text-sm mt-1">Drag to reposition, use slider to zoom</p>
        </div>
        <div class="relative mx-5 rounded-lg overflow-hidden bg-gray-900" data-crop-vp
             style="height: ${vpHeight}px; cursor: grab;">
          <img src="${src}" data-crop-img
               style="position: absolute; left: 0; top: 0; pointer-events: none; user-select: none;" />
          ${mode === "avatar" ? `
          <div class="absolute inset-0 pointer-events-none">
            <svg class="w-full h-full" viewBox="0 0 480 300" preserveAspectRatio="none">
              <defs>
                <mask id="crop-hole">
                  <rect width="480" height="300" fill="white"/>
                  <circle cx="240" cy="150" r="110" fill="black"/>
                </mask>
              </defs>
              <rect width="480" height="300" fill="rgba(0,0,0,0.55)" mask="url(#crop-hole)"/>
              <circle cx="240" cy="150" r="110" fill="none" stroke="white" stroke-width="2" opacity="0.5"/>
            </svg>
          </div>` : ""}
        </div>
        <div class="px-5 py-3 flex items-center gap-3">
          <span class="text-gray-400 text-xs">Zoom</span>
          <input type="range" min="100" max="300" value="100" class="flex-1 accent-indigo-500" data-crop-zoom />
          <span class="text-gray-400 text-xs w-10 text-right" data-crop-zoom-label>1.0x</span>
        </div>
        <div class="px-5 pb-5 flex justify-end gap-3">
          <button type="button" class="px-4 py-2 text-sm text-gray-300 hover:text-white transition" data-crop-cancel>Cancel</button>
          <button type="button" class="px-5 py-2 text-sm bg-indigo-600 hover:bg-indigo-700 text-white rounded font-semibold transition" data-crop-apply>Apply</button>
        </div>
      </div>
    `;
    document.body.appendChild(this.modal);
    this.cropImg = this.modal.querySelector("[data-crop-img]");
    this.cropViewport = this.modal.querySelector("[data-crop-vp]");
    const zoomInput = this.modal.querySelector("[data-crop-zoom]");
    const zoomLabel = this.modal.querySelector("[data-crop-zoom-label]");
    this.cropImg.onload = () => {
      const vw = this.cropViewport.offsetWidth;
      const vh = this.cropViewport.offsetHeight;
      const nw = this.cropImg.naturalWidth;
      const nh = this.cropImg.naturalHeight;
      const scale = Math.min(vw / nw, vh / nh);
      this.baseW = nw * scale;
      this.baseH = nh * scale;
      this.cropImg.style.width = this.baseW + "px";
      this.cropImg.style.height = this.baseH + "px";
      this.cropOffsetX = (vw - this.baseW) / 2;
      this.cropOffsetY = (vh - this.baseH) / 2;
      this.updateCropPosition();
      console.log("[banner-editor] image loaded", nw, "x", nh, "-> base", this.baseW, "x", this.baseH);
    };
    let dragStartX, dragStartY, dragStartOX, dragStartOY;
    const onDown = (e) => {
      e.preventDefault();
      this.cropDragging = true;
      const pt = e.touches ? e.touches[0] : e;
      dragStartX = pt.clientX;
      dragStartY = pt.clientY;
      dragStartOX = this.cropOffsetX;
      dragStartOY = this.cropOffsetY;
      this.cropViewport.style.cursor = "grabbing";
    };
    const onMove = (e) => {
      if (!this.cropDragging)
        return;
      const pt = e.touches ? e.touches[0] : e;
      this.cropOffsetX = dragStartOX + (pt.clientX - dragStartX);
      this.cropOffsetY = dragStartOY + (pt.clientY - dragStartY);
      this.updateCropPosition();
    };
    const onUp = () => {
      this.cropDragging = false;
      if (this.cropViewport)
        this.cropViewport.style.cursor = "grab";
    };
    this.cropViewport.addEventListener("mousedown", onDown);
    this.cropViewport.addEventListener("touchstart", onDown, { passive: false });
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
    document.addEventListener("touchmove", onMove, { passive: false });
    document.addEventListener("touchend", onUp);
    this._cropCleanup = () => {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      document.removeEventListener("touchmove", onMove);
      document.removeEventListener("touchend", onUp);
    };
    zoomInput.addEventListener("input", (e) => {
      const oldScale = this.cropScale;
      this.cropScale = parseInt(e.target.value) / 100;
      zoomLabel.textContent = this.cropScale.toFixed(1) + "x";
      const vw = this.cropViewport.offsetWidth;
      const vh = this.cropViewport.offsetHeight;
      const cx = vw / 2;
      const cy = vh / 2;
      this.cropOffsetX = cx - (cx - this.cropOffsetX) * (this.cropScale / oldScale);
      this.cropOffsetY = cy - (cy - this.cropOffsetY) * (this.cropScale / oldScale);
      this.updateCropPosition();
    });
    this.modal.querySelector("[data-crop-cancel]").addEventListener("click", () => this.cropCancel());
    this.modal.querySelector("[data-crop-apply]").addEventListener("click", () => this.cropApply());
  }
  updateCropPosition() {
    if (!this.cropImg)
      return;
    this.cropImg.style.width = this.baseW + "px";
    this.cropImg.style.height = this.baseH + "px";
    this.cropImg.style.left = "0px";
    this.cropImg.style.top = "0px";
    this.cropImg.style.transformOrigin = "0 0";
    this.cropImg.style.transform = `translate(${this.cropOffsetX}px, ${this.cropOffsetY}px) scale(${this.cropScale})`;
  }
  cropApply() {
    const vw = this.cropViewport.offsetWidth;
    const vh = this.cropViewport.offsetHeight;
    const imgW = this.baseW * this.cropScale;
    const imgH = this.baseH * this.cropScale;
    const nw = this.cropImg.naturalWidth;
    const nh = this.cropImg.naturalHeight;
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d");
    if (this.cropMode === "avatar") {
      const size = 512;
      canvas.width = size;
      canvas.height = size;
      const vpCx = vw / 2;
      const vpCy = vh / 2;
      const r = 110;
      const natPerPx = nw / imgW;
      const sx = (vpCx - r - this.cropOffsetX) * natPerPx;
      const sy = (vpCy - r - this.cropOffsetY) * natPerPx;
      const sw = r * 2 * natPerPx;
      const sh = r * 2 * natPerPx;
      ctx.beginPath();
      ctx.arc(size / 2, size / 2, size / 2, 0, Math.PI * 2);
      ctx.closePath();
      ctx.clip();
      ctx.drawImage(this.cropImg, sx, sy, sw, sh, 0, 0, size, size);
    } else {
      const outW = 960;
      const outH = Math.round(960 * (vh / vw));
      canvas.width = outW;
      canvas.height = outH;
      const natPerPx = nw / imgW;
      const sx = -this.cropOffsetX * natPerPx;
      const sy = -this.cropOffsetY * natPerPx;
      const sw = vw * natPerPx;
      const sh = vh * natPerPx;
      ctx.drawImage(this.cropImg, sx, sy, sw, sh, 0, 0, outW, outH);
    }
    canvas.toBlob((blob) => {
      if (!blob)
        return;
      const file = new File([blob], `cropped_${this.cropMode}.png`, { type: "image/png" });
      const dt = new DataTransfer;
      dt.items.add(file);
      if (this.cropMode === "avatar" && this.hasAvatarInputTarget) {
        this.avatarInputTarget.files = dt.files;
        this.updateAvatarPreviews(canvas.toDataURL());
      } else if (this.cropMode === "banner" && this.hasInputTarget) {
        this.inputTarget.files = dt.files;
        this.updateBannerPreviews(canvas.toDataURL());
      }
      this.closeModal();
    }, "image/png");
  }
  cropCancel() {
    if (this.cropMode === "avatar" && this.hasAvatarInputTarget) {
      this.avatarInputTarget.value = "";
    } else if (this.hasInputTarget) {
      this.inputTarget.value = "";
    }
    this.closeModal();
  }
  closeModal() {
    if (this._cropCleanup)
      this._cropCleanup();
    if (this.modal) {
      this.modal.remove();
      this.modal = null;
    }
    this.cropImg = null;
    this.cropViewport = null;
    this.cropMode = null;
  }
  updateAvatarPreviews(dataUrl) {
    if (this.hasAvatarPreviewTarget) {
      this.avatarPreviewTarget.src = dataUrl;
      this.avatarPreviewTarget.classList.remove("hidden");
    }
    if (this.hasAvatarInitialTarget)
      this.avatarInitialTarget.classList.add("hidden");
    if (this.hasPreviewAvatarTarget) {
      this.previewAvatarTarget.src = dataUrl;
      this.previewAvatarTarget.classList.remove("hidden");
    }
    if (this.hasPreviewAvatarInitialTarget)
      this.previewAvatarInitialTarget.classList.add("hidden");
  }
  updateBannerPreviews(dataUrl) {
    if (this.hasImageTarget) {
      this.imageTarget.src = dataUrl;
      this.imageTarget.style.top = "0px";
      this.imageTarget.classList.remove("hidden");
    }
    if (this.hasPreviewBannerTarget) {
      this.previewBannerTarget.src = dataUrl;
      this.previewBannerTarget.style.top = "0px";
      this.previewBannerTarget.classList.remove("hidden");
    }
    if (this.hasOffsetFieldTarget)
      this.offsetFieldTarget.value = 0;
    if (this.hasHintTarget)
      this.hintTarget.textContent = "";
  }
  previewBannerFile(e) {
    const file = e.target.files[0];
    if (!file)
      return;
    this.openCropModal("banner", file);
  }
  previewAvatarFile(e) {
    const file = e.target.files[0];
    if (!file)
      return;
    this.openCropModal("avatar", file);
  }
  startDrag(e) {
    if (!this.hasImageTarget)
      return;
    e.preventDefault();
    this.dragging = true;
    this.startY = e.clientY;
    this.startOffset = parseInt(this.offsetFieldTarget.value) || 0;
    document.addEventListener("mousemove", this._onMouseMove);
    document.addEventListener("mouseup", this._onMouseUp);
  }
  onDrag(e) {
    if (!this.dragging)
      return;
    const delta = e.clientY - this.startY;
    const containerH = this.containerTarget.offsetHeight;
    const imgEl = this.imageTarget;
    const imageH = imgEl.naturalHeight * (this.containerTarget.offsetWidth / imgEl.naturalWidth);
    const maxOffset = 0;
    const minOffset = Math.min(0, containerH - imageH);
    let newOffset = Math.max(minOffset, Math.min(maxOffset, this.startOffset + delta));
    imgEl.style.top = newOffset + "px";
    this.offsetFieldTarget.value = Math.round(newOffset);
    if (this.hasPreviewBannerTarget) {
      this.previewBannerTarget.style.top = Math.round(newOffset / 1.5) + "px";
    }
  }
  stopDrag() {
    this.dragging = false;
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);
  }
  updateColors() {
    const c1Input = this.element.querySelector('input[name="user[profile_color]"]');
    const c2Input = this.element.querySelector('input[name="user[profile_color_2]"]');
    if (!c1Input || !c2Input)
      return;
    const c1 = c1Input.value;
    const c2 = c2Input.value;
    const grad = `linear-gradient(135deg, ${c1}, ${c2})`;
    if (this.hasPreviewGradientTarget)
      this.previewGradientTarget.style.background = grad;
    if (this.hasPreviewRingTarget)
      this.previewRingTarget.style.background = c2;
    if (this.hasGradientPreviewStripTarget)
      this.gradientPreviewStripTarget.style.background = grad;
  }
  disconnect() {
    document.removeEventListener("mousemove", this._onMouseMove);
    document.removeEventListener("mouseup", this._onMouseUp);
    this.closeModal();
  }
}

// app/javascript/controllers/dm_message_form_controller.js
class dm_message_form_controller_default extends Controller {
  static targets = ["highlight", "input", "filePreview", "dropzone", "replyBar", "replyAuthor", "replyPreview", "parentId"];
  static values = { conversationId: String };
  connect() {
    this.consumer = createConsumer3();
    this.subscription = this.consumer.subscriptions.create({ channel: "ConversationChannel", conversation_id: this.conversationIdValue }, {
      received: (data) => this.handleReceived(data),
      typing() {
        this.perform("typing");
      }
    });
    this.fileList = new DataTransfer;
    this.setupDragAndDrop();
    this.setupPaste();
    this.setupFileIntercept();
    this._replyHandler = (e) => {
      const { messageId, authorName, preview } = e.detail;
      if (this.hasParentIdTarget)
        this.parentIdTarget.value = messageId;
      if (this.hasReplyAuthorTarget)
        this.replyAuthorTarget.textContent = authorName;
      if (this.hasReplyPreviewTarget)
        this.replyPreviewTarget.textContent = preview;
      if (this.hasReplyBarTarget)
        this.replyBarTarget.classList.remove("hidden");
      this.inputTarget.focus();
    };
    document.addEventListener("inferno:reply", this._replyHandler);
    this._measureEmojiWidth();
    this._replaceEmojisWithPUA();
    this.updateHighlight();
    this._emojiMapReady = () => {
      this._replaceEmojisWithPUA();
      this.updateHighlight();
    };
    document.addEventListener("inferno:emoji-map-ready", this._emojiMapReady);
  }
  disconnect() {
    this.subscription?.unsubscribe();
    this.consumer?.disconnect();
    this.teardownDragAndDrop();
    this.teardownPaste();
    this.teardownFileIntercept();
    if (this._emojiMapReady)
      document.removeEventListener("inferno:emoji-map-ready", this._emojiMapReady);
    if (this._replyHandler)
      document.removeEventListener("inferno:reply", this._replyHandler);
  }
  setupPaste() {
    this._pasteHandler = (e) => {
      const items = e.clipboardData?.items;
      if (!items)
        return;
      if (e.clipboardData.types.includes("text/plain") || e.clipboardData.types.includes("text/html"))
        return;
      const files = [];
      for (const item of items) {
        if (item.kind === "file" && item.type.startsWith("image/")) {
          const file = item.getAsFile();
          if (file)
            files.push(file);
        }
      }
      if (files.length > 0) {
        e.preventDefault();
        this.addFiles(files);
      }
    };
    this.element.addEventListener("paste", this._pasteHandler);
  }
  teardownPaste() {
    if (this._pasteHandler) {
      this.element.removeEventListener("paste", this._pasteHandler);
    }
  }
  setupFileIntercept() {
    const form = this.element.querySelector("form");
    if (!form)
      return;
    this._fileInterceptHandler = (event) => {
      const body = event.detail.fetchOptions.body;
      if (body instanceof FormData) {
        const content = body.get("message[content]");
        if (content && window._emojiReverse) {
          body.set("message[content]", content.replace(/\u2003([\uE000-\uF8FF])/g, (m, ch, offset, str) => {
            const name = window._emojiReverse[ch];
            if (!name)
              return m;
            const next = str[offset + m.length];
            return `:${name}:` + (next === " " ? " " : "");
          }));
        }
        if (this.fileList.files.length > 0) {
          body.delete("message[files][]");
          for (const file of this.fileList.files) {
            body.append("message[files][]", file);
          }
        }
      }
    };
    form.addEventListener("turbo:before-fetch-request", this._fileInterceptHandler);
  }
  teardownFileIntercept() {
    const form = this.element.querySelector("form");
    if (form && this._fileInterceptHandler) {
      form.removeEventListener("turbo:before-fetch-request", this._fileInterceptHandler);
    }
  }
  setupDragAndDrop() {
    this._dragCounter = 0;
    this._dragEnter = (e) => {
      e.preventDefault();
      if (!e.dataTransfer?.types?.includes("Files"))
        return;
      this._dragCounter++;
      if (this._dragCounter === 1)
        this.dropzoneTarget.classList.remove("hidden");
    };
    this._dragOver = (e) => {
      e.preventDefault();
    };
    this._dragLeave = (e) => {
      e.preventDefault();
      if (!e.dataTransfer?.types?.includes("Files"))
        return;
      this._dragCounter--;
      if (this._dragCounter <= 0) {
        this._dragCounter = 0;
        this.dropzoneTarget.classList.add("hidden");
      }
    };
    this._drop = (e) => {
      e.preventDefault();
      this._dragCounter = 0;
      this.dropzoneTarget.classList.add("hidden");
      if (e.dataTransfer.files.length) {
        this.addFiles(e.dataTransfer.files);
      }
    };
    document.addEventListener("dragenter", this._dragEnter);
    document.addEventListener("dragover", this._dragOver);
    document.addEventListener("dragleave", this._dragLeave);
    document.addEventListener("drop", this._drop);
  }
  teardownDragAndDrop() {
    document.removeEventListener("dragenter", this._dragEnter);
    document.removeEventListener("dragover", this._dragOver);
    document.removeEventListener("dragleave", this._dragLeave);
    document.removeEventListener("drop", this._drop);
  }
  handleFileSelect(event) {
    this.addFiles(event.target.files);
    event.target.value = "";
    this.syncFileInput();
  }
  addFiles(files) {
    for (const file of files) {
      this.fileList.items.add(file);
    }
    this.syncFileInput();
    this.renderPreviews();
  }
  removeFile(event) {
    const index2 = parseInt(event.currentTarget.dataset.index);
    this.fileList.items.remove(index2);
    this.syncFileInput();
    this.renderPreviews();
  }
  syncFileInput() {
    const input = this.element.querySelector("input[type=file]");
    if (input)
      input.files = this.fileList.files;
  }
  renderPreviews() {
    const container = this.filePreviewTarget;
    container.innerHTML = "";
    if (this.fileList.files.length === 0) {
      container.classList.add("hidden");
      return;
    }
    container.classList.remove("hidden");
    Array.from(this.fileList.files).forEach((file, i) => {
      const wrapper = document.createElement("div");
      wrapper.className = "relative inline-flex items-center bg-gray-700 rounded-lg p-2 mr-2 mb-2";
      if (file.type.startsWith("image/")) {
        const img = document.createElement("img");
        img.className = "w-16 h-16 object-cover rounded";
        img.src = URL.createObjectURL(file);
        wrapper.appendChild(img);
      } else {
        const name = document.createElement("span");
        name.className = "text-xs text-gray-200 max-w-[100px] truncate";
        name.textContent = file.name;
        wrapper.appendChild(name);
      }
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "absolute -top-1.5 -right-1.5 w-5 h-5 bg-red-600 hover:bg-red-500 rounded-full flex items-center justify-center text-white text-xs cursor-pointer";
      btn.innerHTML = "&times;";
      btn.dataset.index = i;
      btn.dataset.action = "click->dm-message-form#removeFile";
      wrapper.appendChild(btn);
      container.appendChild(wrapper);
    });
  }
  setReply(event) {
    const btn = event.currentTarget;
    const messageId = btn.dataset.messageId;
    const authorName = btn.dataset.authorName;
    const preview = btn.dataset.preview;
    this.parentIdTarget.value = messageId;
    this.replyAuthorTarget.textContent = authorName;
    this.replyPreviewTarget.textContent = preview;
    this.replyBarTarget.classList.remove("hidden");
    this.inputTarget.focus();
  }
  clearReply() {
    this.parentIdTarget.value = "";
    this.replyBarTarget.classList.add("hidden");
  }
  handleKeydown(event) {
    if (this._handleEmojiKeydown(event))
      return;
    if (event.key === "Enter" && !event.shiftKey) {
      const content = this.inputTarget.value;
      const backtickCount = (content.match(/`{3}/g) || []).length;
      if (backtickCount % 2 === 1)
        return;
      event.preventDefault();
      const trimmed = content.trim();
      const fileInput = this.element.querySelector("input[type=file]");
      const hasFiles = fileInput && fileInput.files.length > 0;
      if (!trimmed && !hasFiles)
        return;
      const form = event.target.closest("form");
      if (form)
        form.requestSubmit();
    }
  }
  handleSubmit(event) {
    if (event.detail.success) {
      this.inputTarget.value = "";
      this.updateHighlight();
      this.inputTarget.style.height = "auto";
      this.inputTarget.style.fontFamily = "";
      this.inputTarget.style.fontSize = "";
      if (this.inputTarget.parentElement)
        this.inputTarget.parentElement.style.backgroundColor = "";
      this.fileList = new DataTransfer;
      this.syncFileInput();
      this.renderPreviews();
      this.clearReply();
    }
  }
  autoResize() {
    this._replaceEmojisWithPUA();
    this.updateHighlight();
    const input = this.inputTarget;
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 192) + "px";
    this.updateCodeBlockStyle();
  }
  updateCodeBlockStyle() {
    const input = this.inputTarget;
    const val = input.value;
    const tripleCount = (val.match(/`{3}/g) || []).length;
    const inCodeBlock = tripleCount % 2 === 1;
    if (inCodeBlock) {
      input.style.fontFamily = "Consolas, Monaco, 'Courier New', monospace";
      input.style.fontSize = "0.8rem";
      if (input.parentElement)
        input.parentElement.style.backgroundColor = "rgb(30 31 34)";
    } else {
      input.style.fontFamily = "";
      input.style.fontSize = "";
      if (input.parentElement)
        input.parentElement.style.backgroundColor = "";
    }
  }
  handleReceived(data) {
    const messagesDiv = document.getElementById("messages");
    if (!messagesDiv)
      return;
    switch (data.type) {
      case "new_message":
        const welcome = messagesDiv.querySelector(".text-center");
        if (welcome)
          welcome.remove();
        const nearBottom = messagesDiv.scrollHeight - messagesDiv.scrollTop - messagesDiv.clientHeight < 150;
        messagesDiv.insertAdjacentHTML("beforeend", data.html);
        if (nearBottom)
          messagesDiv.scrollTop = messagesDiv.scrollHeight;
        break;
      case "update_message":
        const existing = document.getElementById(`message_${data.message_id}`);
        if (existing)
          existing.outerHTML = data.html;
        break;
      case "delete_message":
        const toDelete = document.getElementById(`message_${data.message_id}`);
        if (toDelete)
          toDelete.remove();
        break;
      case "typing":
        this.showTypingIndicator(data.username, data.user_id);
        break;
    }
  }
  showTypingIndicator(username, userId) {
    const currentUserId = document.body.dataset.currentUserId;
    if (String(userId) === String(currentUserId))
      return;
    const indicator = document.getElementById("typing-indicator");
    if (!indicator)
      return;
    indicator.textContent = `${username} is typing...`;
    clearTimeout(this._typingTimeout);
    this._typingTimeout = setTimeout(() => {
      indicator.textContent = "";
    }, 3000);
  }
  updateHighlight() {
    if (!this.hasHighlightTarget)
      return;
    const text = this.inputTarget.value;
    let html = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    html = html.replace(/(https?:\/\/[^\s<>]+)/gi, '<span class="text-blue-400">$1</span>');
    html = html.replace(/\*\*(.+?)\*\*/g, '<span class="text-white font-bold">**$1**</span>');
    html = html.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, '<span class="text-white italic">*$1*</span>');
    html = html.replace(/~~(.+?)~~/g, '<span class="text-gray-400 line-through">~~$1~~</span>');
    html = html.replace(/`([^`]+)`/g, '<span class="text-orange-300 bg-gray-700/50 rounded px-0.5">`$1`</span>');
    html = html.replace(/(```[\s\S]*?```)/g, '<span class="text-orange-300">$1</span>');
    if (window._emojiReverse && window._emojiMap) {
      html = html.replace(/\u2003([\uE000-\uF8FF])/g, (_, ch) => {
        const name = window._emojiReverse[ch];
        if (name && window._emojiMap[name]) {
          const w = this._emojiCharWidth || 20;
          return `<img src="${window._emojiMap[name]}" style="display:inline;height:${w}px;width:${w}px;object-fit:contain;vertical-align:middle;pointer-events:none">`;
        }
        return _;
      });
    }
    if (html.endsWith(`
`))
      html += "&nbsp;";
    this.highlightTarget.innerHTML = html;
    this.highlightTarget.scrollTop = this.inputTarget.scrollTop;
  }
  _measureEmojiWidth() {
    const canvas = document.createElement("canvas");
    const ctx = canvas.getContext("2d");
    const cs = getComputedStyle(this.inputTarget);
    ctx.font = `${cs.fontSize} ${cs.fontFamily}`;
    this._emojiCharWidth = ctx.measureText(" ").width;
  }
  _replaceEmojisWithPUA() {
    if (!window._emojiPUA || !window._emojiMap)
      return;
    const input = this.inputTarget;
    const val = input.value;
    if (!val.includes(":"))
      return;
    const selStart = input.selectionStart;
    const selEnd = input.selectionEnd;
    let newVal = "";
    let i = 0;
    let newStart = selStart;
    let newEnd = selEnd;
    while (i < val.length) {
      if (val[i] === ":") {
        const rest = val.substring(i + 1);
        const match = rest.match(/^([a-z0-9_]+):/);
        if (match && window._emojiPUA[match[1]]) {
          const fullLen = match[0].length + 1;
          const mEnd = i + fullLen;
          const replacement = " " + window._emojiPUA[match[1]];
          const reduction = fullLen - 2;
          newVal += replacement;
          if (selStart >= mEnd)
            newStart -= reduction;
          else if (selStart > i)
            newStart = newVal.length;
          if (selEnd >= mEnd)
            newEnd -= reduction;
          else if (selEnd > i)
            newEnd = newVal.length;
          i = mEnd;
          continue;
        }
      }
      newVal += val[i];
      i++;
    }
    if (newVal === val)
      return;
    input.value = newVal;
    input.selectionStart = Math.max(0, newStart);
    input.selectionEnd = Math.max(0, newEnd);
  }
  _handleEmojiKeydown(event) {
    if (!window._emojiReverse)
      return false;
    const input = this.inputTarget;
    const val = input.value;
    const pos = input.selectionStart;
    if (pos !== input.selectionEnd)
      return false;
    if (event.key === "Backspace") {
      if (pos >= 2 && val[pos - 2] === " " && window._emojiReverse[val[pos - 1]]) {
        event.preventDefault();
        input.value = val.substring(0, pos - 2) + val.substring(pos);
        input.selectionStart = input.selectionEnd = pos - 2;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
      }
    } else if (event.key === "Delete") {
      if (pos <= val.length - 2 && val[pos] === " " && window._emojiReverse[val[pos + 1]]) {
        event.preventDefault();
        input.value = val.substring(0, pos) + val.substring(pos + 2);
        input.selectionStart = input.selectionEnd = pos;
        input.dispatchEvent(new Event("input", { bubbles: true }));
        return true;
      }
    } else if (event.key === "ArrowLeft" && !event.shiftKey) {
      if (pos >= 2 && val[pos - 2] === " " && window._emojiReverse[val[pos - 1]]) {
        event.preventDefault();
        input.selectionStart = input.selectionEnd = pos - 2;
        return true;
      }
      if (pos >= 1 && val[pos - 1] === " " && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault();
        input.selectionStart = input.selectionEnd = pos - 1;
        return true;
      }
    } else if (event.key === "ArrowRight" && !event.shiftKey) {
      if (pos <= val.length - 2 && val[pos] === " " && window._emojiReverse[val[pos + 1]]) {
        event.preventDefault();
        input.selectionStart = input.selectionEnd = pos + 2;
        return true;
      }
      if (pos > 0 && val[pos - 1] === " " && pos < val.length && window._emojiReverse[val[pos]]) {
        event.preventDefault();
        input.selectionStart = input.selectionEnd = pos + 1;
        return true;
      }
    }
    return false;
  }
}

// app/javascript/controllers/invite_menu_controller.js
class invite_menu_controller_default extends Controller {
  static targets = ["panel", "linkText", "copyBtn", "generateBtn"];
  static values = { baseUrl: String, serverId: String };
  toggle(event) {
    event.stopPropagation();
    this.panelTarget.classList.toggle("hidden");
  }
  copy() {
    const text = this.linkTextTarget.textContent.trim();
    if (!text)
      return;
    navigator.clipboard.writeText(text);
    this.copyBtnTarget.textContent = "Copied!";
    setTimeout(() => this.copyBtnTarget.textContent = "Copy", 2000);
  }
  async generate() {
    this.generateBtnTarget.disabled = true;
    this.generateBtnTarget.textContent = "Generating...";
    try {
      const token = document.querySelector('meta[name="csrf-token"]')?.content;
      const response = await fetch(`/servers/${this.serverIdValue}/settings/invites`, {
        method: "POST",
        headers: {
          "X-CSRF-Token": token,
          Accept: "application/json"
        }
      });
      if (response.ok) {
        const data = await response.json();
        const url = `${this.baseUrlValue}/invite/${data.code}`;
        this.linkTextTarget.textContent = url;
        this.linkTextTarget.classList.remove("italic", "text-gray-500");
        this.linkTextTarget.classList.add("text-gray-300", "select-all");
        this.copyBtnTarget.classList.remove("hidden");
        navigator.clipboard.writeText(url);
        this.copyBtnTarget.textContent = "Copied!";
        setTimeout(() => this.copyBtnTarget.textContent = "Copy", 2000);
      }
    } finally {
      this.generateBtnTarget.disabled = false;
      this.generateBtnTarget.textContent = "Create New Invite";
    }
  }
}

// app/javascript/controllers/video_player_controller.js
class video_player_controller_default extends Controller {
  static targets = ["video"];
  connect() {
    const video = this.videoTarget;
    video.removeAttribute("controls");
    this._injectStyles();
    this._buildOverlay(video);
    this._restoreVolume(video);
    this._bindEvents(video);
    this._onVolumeSync = (e) => {
      if (e.detail.source === this)
        return;
      video.volume = e.detail.volume;
      video.muted = e.detail.muted;
    };
    document.addEventListener("vp:volume", this._onVolumeSync);
  }
  disconnect() {
    if (this._hideTimer)
      clearTimeout(this._hideTimer);
    if (this._mouseMoveHandler) {
      this.element.removeEventListener("mousemove", this._mouseMoveHandler);
    }
    if (this._mouseLeaveHandler) {
      this.element.removeEventListener("mouseleave", this._mouseLeaveHandler);
    }
    if (this._onVolumeSync) {
      document.removeEventListener("vp:volume", this._onVolumeSync);
    }
  }
  _buildOverlay(video) {
    const bigPlay = document.createElement("div");
    bigPlay.className = "vp-big-play";
    bigPlay.innerHTML = `<svg class="w-16 h-16 text-white drop-shadow-lg" fill="currentColor" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>`;
    bigPlay.addEventListener("click", () => this._togglePlay(video));
    this.element.appendChild(bigPlay);
    this._bigPlay = bigPlay;
    const bar = document.createElement("div");
    bar.className = "vp-controls vp-controls-hidden";
    const playBtn = document.createElement("button");
    playBtn.className = "vp-btn";
    playBtn.innerHTML = this._playIcon();
    playBtn.addEventListener("click", () => this._togglePlay(video));
    bar.appendChild(playBtn);
    this._playBtn = playBtn;
    const time = document.createElement("span");
    time.className = "vp-time";
    time.textContent = "0:00 / 0:00";
    bar.appendChild(time);
    this._timeDisplay = time;
    const seekWrap = document.createElement("div");
    seekWrap.className = "vp-seek-wrap";
    const buffered = document.createElement("div");
    buffered.className = "vp-buffered";
    seekWrap.appendChild(buffered);
    this._bufferedBar = buffered;
    const progress = document.createElement("div");
    progress.className = "vp-progress";
    seekWrap.appendChild(progress);
    this._progressBar = progress;
    seekWrap.addEventListener("click", (e) => {
      const rect = seekWrap.getBoundingClientRect();
      const pct = (e.clientX - rect.left) / rect.width;
      video.currentTime = pct * video.duration;
    });
    bar.appendChild(seekWrap);
    const volWrap = document.createElement("div");
    volWrap.className = "vp-vol-wrap";
    const volBtn = document.createElement("button");
    volBtn.className = "vp-btn";
    volBtn.innerHTML = this._volumeIcon(1);
    volBtn.addEventListener("click", () => {
      video.muted = !video.muted;
      this._saveVolume(video.volume, video.muted);
    });
    volWrap.appendChild(volBtn);
    this._volBtn = volBtn;
    const volSlider = document.createElement("input");
    volSlider.type = "range";
    volSlider.min = "0";
    volSlider.max = "1";
    volSlider.step = "0.05";
    volSlider.value = "1";
    volSlider.className = "vp-volume-slider";
    volSlider.addEventListener("input", () => {
      const v = parseFloat(volSlider.value);
      video.volume = v;
      video.muted = v === 0;
      this._saveVolume(v, v === 0);
    });
    volWrap.appendChild(volSlider);
    this._volSlider = volSlider;
    bar.appendChild(volWrap);
    const fsBtn = document.createElement("button");
    fsBtn.className = "vp-btn";
    fsBtn.innerHTML = this._fullscreenIcon();
    fsBtn.addEventListener("click", () => {
      if (document.fullscreenElement) {
        document.exitFullscreen();
      } else {
        this.element.requestFullscreen();
      }
    });
    bar.appendChild(fsBtn);
    this.element.appendChild(bar);
    this._controlsBar = bar;
  }
  _bindEvents(video) {
    video.addEventListener("click", () => this._togglePlay(video));
    video.addEventListener("timeupdate", () => {
      if (!video.duration)
        return;
      const pct = video.currentTime / video.duration * 100;
      this._progressBar.style.width = `${pct}%`;
      this._timeDisplay.textContent = `${this._fmt(video.currentTime)} / ${this._fmt(video.duration)}`;
    });
    video.addEventListener("loadedmetadata", () => this._onMetadata(video));
    video.addEventListener("durationchange", () => this._onMetadata(video));
    if (video.readyState >= 1)
      this._onMetadata(video);
    video.addEventListener("progress", () => {
      if (video.buffered.length > 0) {
        const end = video.buffered.end(video.buffered.length - 1);
        this._bufferedBar.style.width = `${end / video.duration * 100}%`;
      }
    });
    video.addEventListener("play", () => {
      this._playBtn.innerHTML = this._pauseIcon();
      this._bigPlay.classList.add("vp-hidden");
      this._pinned = false;
      this._startAutoHide();
    });
    video.addEventListener("pause", () => {
      this._playBtn.innerHTML = this._playIcon();
      this._bigPlay.classList.remove("vp-hidden");
      if (video.currentTime > 0 && video.currentTime < video.duration) {
        this._showControls();
        this._pinned = true;
      }
    });
    video.addEventListener("ended", () => {
      this._playBtn.innerHTML = this._playIcon();
      this._bigPlay.classList.remove("vp-hidden");
      this._pinned = false;
      this._hideControls();
    });
    video.addEventListener("volumechange", () => {
      const v = video.muted ? 0 : video.volume;
      this._volBtn.innerHTML = this._volumeIcon(v);
      this._volSlider.value = v;
    });
    this._mouseMoveHandler = () => {
      this._showControls();
      if (!video.paused)
        this._startAutoHide();
    };
    this._mouseLeaveHandler = () => {
      if (!video.paused || !this._pinned)
        this._hideControls();
    };
    this.element.addEventListener("mousemove", this._mouseMoveHandler);
    this.element.addEventListener("mouseleave", this._mouseLeaveHandler);
  }
  _togglePlay(video) {
    if (video.paused) {
      video.play();
    } else {
      video.pause();
    }
  }
  _restoreVolume(video) {
    try {
      const saved = localStorage.getItem("videoVolume");
      const muted = localStorage.getItem("videoMuted") === "true";
      if (saved !== null) {
        const v = parseFloat(saved);
        video.volume = v;
        video.muted = muted;
        if (this._volSlider)
          this._volSlider.value = muted ? 0 : v;
        if (this._volBtn)
          this._volBtn.innerHTML = this._volumeIcon(muted ? 0 : v);
      }
    } catch {
    }
  }
  _saveVolume(volume, muted) {
    try {
      localStorage.setItem("videoVolume", volume);
      localStorage.setItem("videoMuted", muted);
    } catch {
    }
    document.dispatchEvent(new CustomEvent("vp:volume", {
      detail: { volume, muted, source: this }
    }));
  }
  _showControls() {
    if (this._hideTimer)
      clearTimeout(this._hideTimer);
    this._controlsBar.classList.remove("vp-controls-hidden");
  }
  _hideControls() {
    this._controlsBar.classList.add("vp-controls-hidden");
  }
  _startAutoHide() {
    if (this._hideTimer)
      clearTimeout(this._hideTimer);
    this._hideTimer = setTimeout(() => this._hideControls(), 2000);
  }
  _onMetadata(video) {
    if (video.duration) {
      this._timeDisplay.textContent = `${this._fmt(video.currentTime)} / ${this._fmt(video.duration)}`;
    }
    if (!this._layoutApplied) {
      this._layoutApplied = true;
      this._applyLayout(video);
    }
  }
  _applyLayout(video) {
    if (video.videoHeight > video.videoWidth) {
      this._controlsBar.classList.add("vp-vertical");
      this._setupVerticalVolume();
    }
  }
  _setupVerticalVolume() {
    this._volSlider.remove();
    const popup = document.createElement("div");
    popup.className = "vp-vol-popup";
    popup.appendChild(this._volSlider);
    this._volSlider.className = "vp-vol-popup-slider";
    this.element.appendChild(popup);
    this._volPopup = popup;
    const positionPopup = () => {
      const containerRect = this.element.getBoundingClientRect();
      const btnRect = this._volBtn.getBoundingClientRect();
      const btnCenterX = btnRect.left + btnRect.width / 2 - containerRect.left;
      popup.style.left = `${btnCenterX - popup.offsetWidth / 2}px`;
    };
    let hideTimeout;
    const show = () => {
      clearTimeout(hideTimeout);
      positionPopup();
      popup.classList.add("vp-vol-popup-visible");
    };
    const hide = () => {
      hideTimeout = setTimeout(() => popup.classList.remove("vp-vol-popup-visible"), 200);
    };
    this._volBtn.parentElement.addEventListener("mouseenter", show);
    this._volBtn.parentElement.addEventListener("mouseleave", hide);
    popup.addEventListener("mouseenter", show);
    popup.addEventListener("mouseleave", hide);
  }
  _fmt(s) {
    if (!s || isNaN(s))
      return "0:00";
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${sec < 10 ? "0" : ""}${sec}`;
  }
  _playIcon() {
    return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>`;
  }
  _pauseIcon() {
    return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>`;
  }
  _volumeIcon(level) {
    if (level === 0) {
      return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51A8.796 8.796 0 0021 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06a8.99 8.99 0 003.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/></svg>`;
    }
    if (level < 0.5) {
      return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M18.5 12c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM5 9v6h4l5 5V4L9 9H5z"/></svg>`;
    }
    return `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"/></svg>`;
  }
  _fullscreenIcon() {
    return `<svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 8V4m0 0h4M4 4l5 5m11-1V4m0 0h-4m4 0l-5 5M4 16v4m0 0h4m-4 0l5-5m11 5v-4m0 4h-4m4 0l-5-5"/></svg>`;
  }
  _injectStyles() {
    if (document.getElementById("video-player-style"))
      return;
    const style = document.createElement("style");
    style.id = "video-player-style";
    style.textContent = `
      [data-controller="video-player"] {
        position: relative;
        cursor: pointer;
      }
      .vp-big-play {
        position: absolute;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 2;
        pointer-events: none;
        transition: opacity 0.2s;
      }
      .vp-big-play.vp-hidden {
        opacity: 0;
        pointer-events: none;
      }
      .vp-controls {
        position: absolute;
        bottom: 0;
        left: 0;
        right: 0;
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 8px 10px;
        background: linear-gradient(to top, rgba(0,0,0,0.8), transparent);
        z-index: 3;
        transform: translateY(0);
        opacity: 1;
        transition: transform 0.25s ease, opacity 0.25s ease;
      }
      .vp-controls.vp-controls-hidden {
        transform: translateY(100%);
        opacity: 0;
        pointer-events: none;
      }
      .vp-btn {
        background: none;
        border: none;
        color: #e5e7eb;
        cursor: pointer;
        padding: 2px;
        display: flex;
        align-items: center;
        justify-content: center;
        flex-shrink: 0;
        transition: color 0.15s;
      }
      .vp-btn:hover { color: #fff; }
      .vp-time {
        font-size: 12px;
        color: #9ca3af;
        white-space: nowrap;
        flex-shrink: 0;
        user-select: none;
      }
      .vp-seek-wrap {
        flex: 1;
        height: 4px;
        background: rgba(255,255,255,0.2);
        border-radius: 2px;
        position: relative;
        cursor: pointer;
        min-width: 60px;
      }
      .vp-seek-wrap:hover {
        height: 6px;
      }
      .vp-buffered {
        position: absolute;
        top: 0;
        left: 0;
        height: 100%;
        background: rgba(255,255,255,0.25);
        border-radius: 2px;
        pointer-events: none;
        width: 0%;
      }
      .vp-progress {
        position: absolute;
        top: 0;
        left: 0;
        height: 100%;
        background: #3b82f6;
        border-radius: 2px;
        pointer-events: none;
        width: 0%;
      }
      .vp-vol-wrap {
        position: relative;
        display: flex;
        align-items: center;
        flex-shrink: 0;
      }
      .vp-volume-slider {
        width: 60px;
        height: 4px;
        -webkit-appearance: none;
        appearance: none;
        background: rgba(255,255,255,0.2);
        border-radius: 2px;
        outline: none;
        cursor: pointer;
        flex-shrink: 0;
      }
      .vp-volume-slider::-webkit-slider-thumb {
        -webkit-appearance: none;
        width: 12px;
        height: 12px;
        border-radius: 50%;
        background: #fff;
        cursor: pointer;
      }
      .vp-volume-slider::-moz-range-thumb {
        width: 12px;
        height: 12px;
        border-radius: 50%;
        background: #fff;
        cursor: pointer;
        border: none;
      }
      .vp-volume-slider::-webkit-slider-runnable-track {
        height: 4px;
        border-radius: 2px;
      }
      .vp-volume-slider::-moz-range-track {
        height: 4px;
        border-radius: 2px;
        background: rgba(255,255,255,0.2);
      }
      /* Vertical video layout */
      .vp-vertical {
        flex-wrap: wrap;
        gap: 4px 8px;
      }
      .vp-vertical .vp-seek-wrap {
        order: -1;
        width: 100%;
        flex: none;
        min-width: 0;
      }
      .vp-vertical .vp-time {
        flex: 1;
        font-size: 11px;
      }
      /* Vertical volume popup */
      .vp-vol-popup {
        position: absolute;
        bottom: 52px;
        background: rgba(0,0,0,0.85);
        border-radius: 6px;
        padding: 10px 6px;
        z-index: 4;
        opacity: 0;
        pointer-events: none;
        transition: opacity 0.2s;
      }
      .vp-vol-popup-visible {
        opacity: 1;
        pointer-events: auto;
      }
      .vp-vol-popup-slider {
        writing-mode: vertical-lr;
        direction: rtl;
        width: 4px;
        height: 80px;
        -webkit-appearance: none;
        appearance: none;
        background: rgba(255,255,255,0.2);
        border-radius: 2px;
        outline: none;
        cursor: pointer;
      }
      .vp-vol-popup-slider::-webkit-slider-thumb {
        -webkit-appearance: none;
        width: 14px;
        height: 14px;
        border-radius: 50%;
        background: #fff;
        cursor: pointer;
      }
      .vp-vol-popup-slider::-moz-range-thumb {
        width: 14px;
        height: 14px;
        border-radius: 50%;
        background: #fff;
        cursor: pointer;
        border: none;
      }
      /* Fullscreen: center and scale video */
      [data-controller="video-player"]:fullscreen {
        display: flex;
        align-items: center;
        justify-content: center;
        background: #000;
      }
      [data-controller="video-player"]:fullscreen video {
        max-width: 100% !important;
        max-height: 100vh !important;
        width: 100%;
        height: 100%;
        object-fit: contain;
      }
    `;
    document.head.appendChild(style);
  }
}

// app/javascript/controllers/nostr_key_export_controller.js
class nostr_key_export_controller_default extends Controller {
  static targets = [
    "copyNpubBtn",
    "passwordInput",
    "passwordForm",
    "keyDisplay",
    "nsecValue",
    "error",
    "encryptedSection",
    "encryptedPasswordInput",
    "backupPasswordInput",
    "encryptedResult",
    "ncryptsecValue",
    "encryptedError",
    "encryptedForm"
  ];
  async copyNpub(event) {
    const value = event.currentTarget.dataset.value;
    await navigator.clipboard.writeText(value);
    const btn = this.copyNpubBtnTarget;
    btn.textContent = "Copied!";
    setTimeout(() => {
      btn.textContent = "Copy";
    }, 2000);
  }
  async revealKey() {
    const password = this.passwordInputTarget.value;
    if (!password) {
      this.showError("Please enter your password");
      return;
    }
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    try {
      const response = await fetch("/settings/reveal_nostr_key", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ password })
      });
      const data = await response.json();
      if (response.ok) {
        this.nsecValueTarget.textContent = data.nsec;
        this.passwordFormTarget.classList.add("hidden");
        this.keyDisplayTarget.classList.remove("hidden");
        this.hideError();
      } else {
        this.showError(data.error || "Failed to reveal key");
      }
    } catch {
      this.showError("Network error. Please try again.");
    }
  }
  async copyNsec() {
    const value = this.nsecValueTarget.textContent;
    await navigator.clipboard.writeText(value);
    const btn = this.keyDisplayTarget.querySelector("button");
    btn.textContent = "Copied!";
    setTimeout(() => {
      btn.textContent = "Copy";
    }, 2000);
  }
  async exportEncrypted() {
    const password = this.encryptedPasswordInputTarget.value;
    const backupPassword = this.backupPasswordInputTarget.value;
    if (!password) {
      this.showEncryptedError("Please enter your account password");
      return;
    }
    if (!backupPassword || backupPassword.length < 8) {
      this.showEncryptedError("Backup password must be at least 8 characters");
      return;
    }
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    try {
      const response = await fetch("/settings/export_encrypted_key", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ password, backup_password: backupPassword })
      });
      const data = await response.json();
      if (response.ok) {
        this.ncryptsecValueTarget.textContent = data.ncryptsec;
        this.encryptedFormTarget.classList.add("hidden");
        this.encryptedResultTarget.classList.remove("hidden");
        this.hideEncryptedError();
      } else {
        this.showEncryptedError(data.error || "Failed to export key");
      }
    } catch {
      this.showEncryptedError("Network error. Please try again.");
    }
  }
  async copyNcryptsec() {
    const value = this.ncryptsecValueTarget.textContent;
    await navigator.clipboard.writeText(value);
    const btn = this.encryptedResultTarget.querySelector("button");
    btn.textContent = "Copied!";
    setTimeout(() => {
      btn.textContent = "Copy";
    }, 2000);
  }
  showError(message) {
    this.errorTarget.textContent = message;
    this.errorTarget.classList.remove("hidden");
  }
  hideError() {
    this.errorTarget.classList.add("hidden");
  }
  showEncryptedError(message) {
    this.encryptedErrorTarget.textContent = message;
    this.encryptedErrorTarget.classList.remove("hidden");
  }
  hideEncryptedError() {
    this.encryptedErrorTarget.classList.add("hidden");
  }
}

// app/javascript/controllers/role_editor_controller.js
var PERMISSION_GROUPS = {
  General: {
    read_messages: "View channels and read messages",
    read_message_history: "Read message history",
    create_invite: "Create invite links",
    change_nickname: "Change their own nickname in this server"
  },
  Text: {
    send_messages: "Send messages in text channels",
    attach_files: "Upload images and files",
    send_gifs: "Send GIFs in messages",
    add_reactions: "Add emoji reactions to messages",
    mention_everyone: "Use @everyone and @here mentions"
  },
  Expression: {
    send_custom_emojis: "Use custom server emojis in messages",
    send_custom_stickers: "Use custom server stickers in messages",
    create_emojis: "Upload custom emojis to the server",
    create_stickers: "Upload custom stickers to the server",
    manage_emojis: "Delete emojis and stickers uploaded by others"
  },
  Management: {
    manage_messages: "Delete or pin other members' messages",
    manage_channels: "Create, edit, and delete channels",
    manage_roles: "Create, edit, and reorder roles",
    manage_invites: "View and revoke invite links",
    manage_server: "Edit server name, icon, and settings"
  },
  Moderation: {
    kick_members: "Remove members from the server",
    ban_members: "Permanently ban members"
  },
  Dangerous: {
    administrator: "Full admin access — bypasses all permission checks"
  }
};

class role_editor_controller_default extends Controller {
  static targets = [
    "rolesData",
    "roleList",
    "emptyState",
    "editorForm",
    "editorTitle",
    "deleteBtn",
    "nameInput",
    "colorInput",
    "colorHex",
    "permissionsSection",
    "saveBar",
    "roleName"
  ];
  static values = { serverId: String, canManage: Boolean };
  connect() {
    this.roles = JSON.parse(this.rolesDataTarget.textContent);
    this.selectedRoleId = null;
    this.originalData = null;
    this.dirty = false;
    if (this.canManageValue) {
      this.sortable = sortable_esm_default.create(this.roleListTarget, {
        animation: 150,
        ghostClass: "opacity-20",
        chosenClass: "bg-gray-600",
        onEnd: () => this.handleReorder()
      });
    }
  }
  disconnect() {
    if (this.sortable)
      this.sortable.destroy();
  }
  selectRole(e) {
    const id = e.currentTarget.dataset.roleId;
    if (id === this.selectedRoleId)
      return;
    if (this.dirty) {
      if (!confirm("You have unsaved changes. Discard them?"))
        return;
    }
    this.selectedRoleId = id;
    const role = this.roles.find((r) => r.id === id);
    if (!role)
      return;
    this.originalData = JSON.parse(JSON.stringify(role));
    this.dirty = false;
    this.saveBarTarget.classList.add("hidden");
    this.roleListTarget.querySelectorAll("[data-role-id]").forEach((el) => {
      el.classList.toggle("bg-gray-600", el.dataset.roleId === id);
      el.classList.toggle("bg-gray-800", el.dataset.roleId !== id);
    });
    this.populateEditor(role);
  }
  populateEditor(role) {
    this.editorFormTarget.classList.remove("hidden");
    this.emptyStateTarget.classList.add("hidden");
    this.editorTitleTarget.textContent = role.name;
    this.roleNameTarget.textContent = role.name;
    if (role.is_owner || role.is_everyone) {
      this.deleteBtnTarget.classList.add("hidden");
    } else {
      this.deleteBtnTarget.classList.remove("hidden");
    }
    this.nameInputTarget.value = role.name;
    this.colorInputTarget.value = role.color || "#99aab5";
    this.colorHexTarget.textContent = (role.color || "#99aab5").toUpperCase();
    const disableDisplay = role.is_everyone || role.is_owner;
    this.nameInputTarget.disabled = disableDisplay;
    this.colorInputTarget.disabled = disableDisplay;
    if (disableDisplay) {
      this.nameInputTarget.classList.add("opacity-50");
      this.colorInputTarget.classList.add("opacity-50");
    } else {
      this.nameInputTarget.classList.remove("opacity-50");
      this.colorInputTarget.classList.remove("opacity-50");
    }
    const hoistToggle = this.element.querySelector("[data-hoist-toggle]");
    if (hoistToggle) {
      if (role.is_everyone || role.is_owner) {
        hoistToggle.closest("[data-hoist-row]").classList.add("hidden");
      } else {
        hoistToggle.closest("[data-hoist-row]").classList.remove("hidden");
        if (role.hoist) {
          hoistToggle.classList.remove("bg-gray-600");
          hoistToggle.classList.add("bg-orange-600");
          hoistToggle.firstElementChild.classList.remove("translate-x-0.5");
          hoistToggle.firstElementChild.classList.add("translate-x-5");
        } else {
          hoistToggle.classList.remove("bg-orange-600");
          hoistToggle.classList.add("bg-gray-600");
          hoistToggle.firstElementChild.classList.remove("translate-x-5");
          hoistToggle.firstElementChild.classList.add("translate-x-0.5");
        }
      }
    }
    this.renderPermissions(role);
  }
  renderPermissions(role) {
    const container = this.permissionsSectionTarget;
    container.innerHTML = "";
    if (role.is_owner) {
      container.innerHTML = '<p class="text-sm text-gray-500 italic">The Owner role has all permissions and cannot be edited.</p>';
      return;
    }
    for (const [groupName, perms] of Object.entries(PERMISSION_GROUPS)) {
      const groupDiv = document.createElement("div");
      groupDiv.className = "mb-6";
      const heading = document.createElement("h4");
      heading.className = "text-xs font-bold text-gray-400 uppercase tracking-wide mb-3";
      heading.textContent = groupName;
      groupDiv.appendChild(heading);
      for (const [key, description] of Object.entries(perms)) {
        const enabled = role.permissions && role.permissions[key] === true;
        const row = document.createElement("div");
        row.className = "flex items-center justify-between py-2 border-b border-gray-700/50";
        const labelDiv = document.createElement("div");
        labelDiv.className = "flex-1 mr-4";
        const label = document.createElement("p");
        label.className = "text-sm text-white";
        label.textContent = key.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
        labelDiv.appendChild(label);
        const desc = document.createElement("p");
        desc.className = "text-xs text-gray-500";
        desc.textContent = description;
        labelDiv.appendChild(desc);
        row.appendChild(labelDiv);
        const toggle = document.createElement("button");
        toggle.type = "button";
        toggle.className = `relative w-11 h-6 rounded-full transition-colors focus:outline-none ${enabled ? "bg-orange-600" : "bg-gray-600"}`;
        toggle.dataset.permission = key;
        toggle.dataset.action = "click->role-editor#togglePermission";
        const knob = document.createElement("span");
        knob.className = `block w-5 h-5 bg-white rounded-full shadow transform transition-transform ${enabled ? "translate-x-5" : "translate-x-0.5"}`;
        toggle.appendChild(knob);
        row.appendChild(toggle);
        groupDiv.appendChild(row);
      }
      container.appendChild(groupDiv);
    }
  }
  togglePermission(e) {
    const btn = e.currentTarget;
    const key = btn.dataset.permission;
    const role = this.roles.find((r) => r.id === this.selectedRoleId);
    if (!role)
      return;
    const newVal = !(role.permissions && role.permissions[key] === true);
    if (!role.permissions)
      role.permissions = {};
    role.permissions[key] = newVal;
    if (newVal) {
      btn.classList.remove("bg-gray-600");
      btn.classList.add("bg-orange-600");
      btn.firstElementChild.classList.remove("translate-x-0.5");
      btn.firstElementChild.classList.add("translate-x-5");
    } else {
      btn.classList.remove("bg-orange-600");
      btn.classList.add("bg-gray-600");
      btn.firstElementChild.classList.remove("translate-x-5");
      btn.firstElementChild.classList.add("translate-x-0.5");
    }
    this.markDirty();
  }
  toggleHoist(e) {
    const btn = e.currentTarget;
    const role = this.roles.find((r) => r.id === this.selectedRoleId);
    if (!role)
      return;
    role.hoist = !role.hoist;
    if (role.hoist) {
      btn.classList.remove("bg-gray-600");
      btn.classList.add("bg-orange-600");
      btn.firstElementChild.classList.remove("translate-x-0.5");
      btn.firstElementChild.classList.add("translate-x-5");
    } else {
      btn.classList.remove("bg-orange-600");
      btn.classList.add("bg-gray-600");
      btn.firstElementChild.classList.remove("translate-x-5");
      btn.firstElementChild.classList.add("translate-x-0.5");
    }
    this.markDirty();
  }
  previewColor() {
    const color = this.colorInputTarget.value;
    this.colorHexTarget.textContent = color.toUpperCase();
    const role = this.roles.find((r) => r.id === this.selectedRoleId);
    if (role)
      role.color = color;
    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`);
    if (listItem) {
      const dot = listItem.querySelector("[data-color-dot]");
      if (dot)
        dot.style.backgroundColor = color;
    }
    this.markDirty();
  }
  updateName() {
    const name = this.nameInputTarget.value;
    const role = this.roles.find((r) => r.id === this.selectedRoleId);
    if (role)
      role.name = name;
    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`);
    if (listItem) {
      const nameEl = listItem.querySelector("[data-role-name]");
      if (nameEl)
        nameEl.textContent = name;
    }
    this.editorTitleTarget.textContent = name;
    this.roleNameTarget.textContent = name;
    this.markDirty();
  }
  markDirty() {
    this.dirty = true;
    this.saveBarTarget.classList.remove("hidden");
  }
  resetChanges() {
    if (!this.originalData)
      return;
    const idx = this.roles.findIndex((r) => r.id === this.selectedRoleId);
    if (idx !== -1) {
      this.roles[idx] = JSON.parse(JSON.stringify(this.originalData));
    }
    this.dirty = false;
    this.saveBarTarget.classList.add("hidden");
    this.populateEditor(this.roles[idx]);
    const listItem = this.roleListTarget.querySelector(`[data-role-id="${this.selectedRoleId}"]`);
    if (listItem) {
      const dot = listItem.querySelector("[data-color-dot]");
      if (dot)
        dot.style.backgroundColor = this.originalData.color || "#99aab5";
      const nameEl = listItem.querySelector("[data-role-name]");
      if (nameEl)
        nameEl.textContent = this.originalData.name;
    }
  }
  async saveRole() {
    const role = this.roles.find((r) => r.id === this.selectedRoleId);
    if (!role)
      return;
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles/${role.id}`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({
          name: role.name,
          color: role.color,
          hoist: role.hoist,
          permissions: role.permissions
        })
      });
      if (res.ok) {
        const updated = await res.json();
        const idx = this.roles.findIndex((r) => r.id === this.selectedRoleId);
        if (idx !== -1)
          this.roles[idx] = updated;
        this.originalData = JSON.parse(JSON.stringify(updated));
        this.dirty = false;
        this.saveBarTarget.classList.add("hidden");
        this.showToast("Role saved!");
      } else {
        const data = await res.json();
        this.showToast(data.error || data.errors?.join(", ") || "Save failed", true);
      }
    } catch (err) {
      this.showToast("Network error", true);
    }
  }
  async createRole() {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles`, {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({})
      });
      if (res.ok) {
        const role = await res.json();
        this.roles.push(role);
        this.appendRoleToList(role);
        this.selectedRoleId = role.id;
        this.originalData = JSON.parse(JSON.stringify(role));
        this.dirty = false;
        this.saveBarTarget.classList.add("hidden");
        this.roleListTarget.querySelectorAll("[data-role-id]").forEach((el) => {
          el.classList.toggle("bg-gray-600", el.dataset.roleId === role.id);
          el.classList.toggle("bg-gray-800", el.dataset.roleId !== role.id);
        });
        this.populateEditor(role);
        this.showToast("Role created!");
      } else {
        const data = await res.json();
        this.showToast(data.errors?.join(", ") || "Create failed", true);
      }
    } catch (err) {
      this.showToast("Network error", true);
    }
  }
  async deleteRole() {
    const role = this.roles.find((r) => r.id === this.selectedRoleId);
    if (!role || role.is_owner || role.is_everyone)
      return;
    if (!confirm(`Delete "${role.name}"? Members with this role will be moved to @everyone.`))
      return;
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/roles/${role.id}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      });
      if (res.ok) {
        this.roles = this.roles.filter((r) => r.id !== role.id);
        const listItem = this.roleListTarget.querySelector(`[data-role-id="${role.id}"]`);
        if (listItem)
          listItem.remove();
        this.selectedRoleId = null;
        this.originalData = null;
        this.dirty = false;
        this.editorFormTarget.classList.add("hidden");
        this.emptyStateTarget.classList.remove("hidden");
        this.saveBarTarget.classList.add("hidden");
        this.showToast("Role deleted!");
      } else {
        const data = await res.json();
        this.showToast(data.error || "Delete failed", true);
      }
    } catch (err) {
      this.showToast("Network error", true);
    }
  }
  async handleReorder() {
    const items = this.roleListTarget.querySelectorAll("[data-role-id]");
    const rolesPayload = [];
    const sortableItems = Array.from(items);
    const maxPos = sortableItems.length;
    sortableItems.forEach((el, idx) => {
      const pos = maxPos - idx;
      rolesPayload.push({ id: el.dataset.roleId, position: pos });
      const role = this.roles.find((r) => r.id === el.dataset.roleId);
      if (role)
        role.position = pos;
    });
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    try {
      const res = await fetch(`/servers/${this.serverIdValue}/reorder_roles`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({ roles: rolesPayload })
      });
      if (res.ok) {
        this.showToast("Role order saved!");
      } else {
        this.showToast("Failed to save order", true);
      }
    } catch (err) {
      this.showToast("Network error", true);
    }
  }
  appendRoleToList(role) {
    const item = document.createElement("div");
    item.className = "flex items-center px-3 py-2 rounded cursor-pointer bg-gray-800 hover:bg-gray-700 transition-colors";
    item.dataset.roleId = role.id;
    item.dataset.action = "click->role-editor#selectRole";
    item.innerHTML = `
      <span class="w-3 h-3 rounded-full mr-3 shrink-0" data-color-dot style="background-color: ${this.escapeHtml(role.color || "#99aab5")}"></span>
      <span class="flex-1 text-sm text-white truncate" data-role-name>${this.escapeHtml(role.name)}</span>
      <span class="text-xs text-gray-500 ml-2">${role.member_count}</span>
    `;
    const everyoneItem = Array.from(this.roleListTarget.children).find((el) => {
      const role2 = this.roles.find((r) => r.id === el.dataset.roleId);
      return role2 && role2.is_everyone;
    });
    if (everyoneItem) {
      this.roleListTarget.insertBefore(item, everyoneItem);
    } else {
      this.roleListTarget.appendChild(item);
    }
  }
  escapeHtml(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }
  showToast(msg, isError = false) {
    const toast = document.createElement("div");
    toast.className = `fixed bottom-6 right-6 ${isError ? "bg-red-600" : "bg-green-600"} text-white px-4 py-2 rounded-lg shadow-lg z-[200] text-sm font-medium`;
    toast.textContent = msg;
    document.body.appendChild(toast);
    setTimeout(() => toast.remove(), 2000);
  }
}

// app/javascript/controllers/member_roles_controller.js
class member_roles_controller_default extends Controller {
  static values = {
    serverId: String,
    membershipId: String,
    allRoles: Array,
    currentRoleIds: Array
  };
  static targets = ["dropdown", "badges"];
  connect() {
    this.boundCloseDropdown = this.closeDropdown.bind(this);
  }
  disconnect() {
    document.removeEventListener("click", this.boundCloseDropdown);
  }
  toggle(event) {
    event.stopPropagation();
    const dropdown = this.dropdownTarget;
    const isHidden = dropdown.classList.contains("hidden");
    if (isHidden) {
      dropdown.classList.remove("hidden");
      setTimeout(() => document.addEventListener("click", this.boundCloseDropdown), 10);
    } else {
      this.closeDropdown();
    }
  }
  closeDropdown(event) {
    if (event && this.dropdownTarget.contains(event.target))
      return;
    this.dropdownTarget.classList.add("hidden");
    document.removeEventListener("click", this.boundCloseDropdown);
  }
  async toggleRole(event) {
    event.stopPropagation();
    const checkboxes = this.dropdownTarget.querySelectorAll("input[type=checkbox]");
    const roleIds = Array.from(checkboxes).filter((cb) => cb.checked).map((cb) => cb.value);
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
      const response = await fetch(`/servers/${this.serverIdValue}/settings/members/${this.membershipIdValue}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: JSON.stringify({ role_ids: roleIds })
      });
      if (!response.ok)
        throw new Error("Failed to update roles");
      const data = await response.json();
      this.updateBadges(data.roles);
      this.showToast("Roles updated", "success");
    } catch (error2) {
      this.showToast("Failed to update roles", "error");
    }
  }
  updateBadges(roles) {
    const badgesEl = this.badgesTarget;
    if (!badgesEl)
      return;
    if (roles.length === 0) {
      badgesEl.innerHTML = '<span class="inline-flex items-center text-xs px-2 py-0.5 rounded-full bg-gray-700 text-gray-400">@everyone</span>';
      return;
    }
    badgesEl.innerHTML = roles.map((role) => {
      const bgClass = role.name === "Admin" ? "bg-red-600/20 text-red-400" : "bg-gray-700 text-gray-400";
      return `<span class="inline-flex items-center text-xs px-2 py-0.5 rounded-full ${bgClass}">
        <span class="w-2 h-2 rounded-full mr-1" style="background-color: ${role.color || "#ffffff"}"></span>
        ${this.escapeHtml(role.name)}
      </span>`;
    }).join("");
  }
  escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }
  showToast(message, type) {
    const toast = document.getElementById("toast");
    if (!toast)
      return;
    toast.textContent = message;
    toast.className = `fixed top-4 right-4 px-4 py-2 rounded-lg shadow-lg text-sm font-medium z-[100] transition-opacity duration-300 ${type === "success" ? "bg-green-600 text-white" : "bg-red-600 text-white"}`;
    toast.classList.remove("hidden", "opacity-0");
    setTimeout(() => {
      toast.classList.add("opacity-0");
      setTimeout(() => toast.classList.add("hidden"), 300);
    }, 3000);
  }
}

// app/javascript/controllers/server_rail_controller.js
class server_rail_controller_default extends Controller {
  static targets = ["list", "folderList"];
  connect() {
    this.sortables = [];
    this.folderMenu = null;
    this.boundCloseMenu = this.closeFolderMenu.bind(this);
    this.boundKeydown = this.handleKeydown.bind(this);
    this.dragOverTarget = null;
    this.folderCreationReady = false;
    this.folderCreationTimer = null;
    if (this.hasListTarget) {
      this.initMainSortable();
      this.initFolderSortables();
    }
    this.freezeGifs();
  }
  disconnect() {
    this.sortables.forEach((s) => s.destroy());
    this.sortables = [];
    this.closeFolderMenu();
    clearTimeout(this.folderCreationTimer);
  }
  initMainSortable() {
    const sortable = sortable_esm_default.create(this.listTarget, {
      animation: 150,
      ghostClass: "opacity-20",
      dragClass: "shadow-lg",
      draggable: "[data-rail-item], [data-server-id]",
      fallbackOnBody: true,
      swapThreshold: 0.65,
      group: "rail",
      onStart: () => this.onDragStart(),
      onEnd: (evt) => this.handleMainDrop(evt),
      onMove: (evt) => this.handleDragMove(evt),
      onAdd: (evt) => {
        evt.item.setAttribute("data-rail-item", "server");
      }
    });
    this.sortables.push(sortable);
  }
  initFolderSortables() {
    this.element.querySelectorAll("[data-folder-server-list]").forEach((list) => {
      this.initSingleFolderSortable(list);
    });
  }
  initSingleFolderSortable(list) {
    if (list._sortableInitialized)
      return;
    const sortable = sortable_esm_default.create(list, {
      animation: 150,
      ghostClass: "opacity-20",
      dragClass: "shadow-lg",
      draggable: "[data-server-id]",
      fallbackOnBody: true,
      swapThreshold: 0.65,
      group: "rail",
      onEnd: () => this.saveOrder(),
      onAdd: (evt) => this.handleFolderAdd(evt),
      onRemove: (evt) => this.handleFolderRemove(evt)
    });
    this.sortables.push(sortable);
    list._sortableInitialized = true;
  }
  onDragStart() {
    this.dragOverTarget = null;
    this.folderCreationReady = false;
    clearTimeout(this.folderCreationTimer);
  }
  handleDragMove(evt) {
    const dragged = evt.dragged;
    const related = evt.related;
    if (!dragged || !related) {
      this.clearFolderCreationState();
      return true;
    }
    if (dragged.dataset.railItem === "folder" || related.dataset.railItem === "folder") {
      this.clearFolderCreationState();
      return true;
    }
    if (!dragged.dataset.serverId || !related.dataset.serverId) {
      this.clearFolderCreationState();
      return true;
    }
    if (related.closest("[data-folder-server-list]")) {
      this.clearFolderCreationState();
      return true;
    }
    if (this.dragOverTarget === related)
      return true;
    this.clearFolderCreationState();
    related.classList.add("folder-drop-target");
    this.dragOverTarget = related;
    this.folderCreationTimer = setTimeout(() => {
      this.folderCreationReady = true;
      if (this.dragOverTarget) {
        this.dragOverTarget.classList.remove("folder-drop-target");
        this.dragOverTarget.classList.add("folder-drop-ready");
      }
    }, 500);
    return true;
  }
  clearFolderCreationState() {
    clearTimeout(this.folderCreationTimer);
    this.folderCreationReady = false;
    if (this.dragOverTarget) {
      this.dragOverTarget.classList.remove("folder-drop-target", "folder-drop-ready");
      this.dragOverTarget = null;
    }
    this.element.querySelectorAll(".folder-drop-target, .folder-drop-ready").forEach((el) => {
      el.classList.remove("folder-drop-target", "folder-drop-ready");
    });
  }
  async handleMainDrop(evt) {
    const shouldCreateFolder = this.folderCreationReady;
    const target = this.dragOverTarget;
    this.clearFolderCreationState();
    const dragged = evt.item;
    if (shouldCreateFolder && target && dragged.dataset.serverId && target.dataset.serverId && dragged !== target && !dragged.dataset.folderId && !target.dataset.folderId) {
      await this.createFolder(dragged.dataset.serverId, target.dataset.serverId, dragged, target);
      return;
    }
    this.saveOrder();
  }
  async createFolder(serverId1, serverId2, el1, el2) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    try {
      const response = await fetch("/server_folders", {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({
          server_folder: { name: "Folder" },
          server_ids: [serverId1, serverId2]
        })
      });
      if (!response.ok)
        return this.saveOrder();
      const data = await response.json();
      const temp = document.createElement("div");
      temp.innerHTML = data.html;
      const folderEl = temp.firstElementChild;
      el1.replaceWith(folderEl);
      el2.remove();
      const newFolderList = folderEl.querySelector("[data-folder-server-list]");
      if (newFolderList) {
        this.initSingleFolderSortable(newFolderList);
      }
      this.freezeGifs();
      this.saveOrder();
    } catch (e) {
      this.saveOrder();
    }
  }
  handleFolderAdd(evt) {
    const folderEl = evt.to.closest("[data-folder-id]");
    if (folderEl)
      this.updateFolderIcons(folderEl);
    this.saveOrder();
  }
  handleFolderRemove(evt) {
    const folderEl = evt.from.closest("[data-folder-id]");
    if (!folderEl)
      return;
    const serverList = folderEl.querySelector("[data-folder-server-list]");
    if (serverList && serverList.children.length === 0) {
      const folderId = folderEl.dataset.folderId;
      folderEl.remove();
      this.deleteFolder(folderId, false);
    } else {
      this.updateFolderIcons(folderEl);
    }
    this.saveOrder();
  }
  updateFolderIcons(folderEl) {
    const serverList = folderEl.querySelector("[data-folder-server-list]");
    if (!serverList)
      return;
    const servers = Array.from(serverList.children).filter((el) => el.dataset.serverId);
    const offsets = [
      { x: -4, y: -4 },
      { x: 6, y: -2 },
      { x: 1, y: 6 }
    ];
    folderEl.querySelectorAll("[data-folder-icons]").forEach((container) => {
      const folderColor = container.dataset.folderColor || "#4f545c";
      container.style.backgroundColor = folderColor;
      container.innerHTML = "";
      servers.slice(0, 3).forEach((serverEl, i) => {
        const offset = offsets[i];
        const mini = document.createElement("div");
        mini.className = "absolute w-5 h-5 rounded-md overflow-hidden border border-gray-800";
        mini.style.transform = `translate(${offset.x}px, ${offset.y}px)`;
        mini.style.zIndex = 3 - i;
        const frozenCanvas = serverEl.querySelector("[data-gif-freeze]");
        const img = serverEl.querySelector("img:not(.gif-animated)");
        if (frozenCanvas && frozenCanvas.width > 0) {
          const miniImg = document.createElement("img");
          try {
            miniImg.src = frozenCanvas.toDataURL();
          } catch (e) {
            miniImg.src = "";
          }
          miniImg.className = "w-full h-full object-cover";
          mini.appendChild(miniImg);
        } else if (img) {
          const miniImg = document.createElement("img");
          miniImg.src = img.src;
          miniImg.className = "w-full h-full object-cover";
          mini.appendChild(miniImg);
        } else {
          const span = serverEl.querySelector("span.text-white");
          const initials = span ? span.textContent.trim() : "?";
          const div = document.createElement("div");
          div.className = "w-full h-full bg-gray-600 flex items-center justify-center";
          div.innerHTML = `<span class="text-white text-[6px] font-bold">${this.escapeAttr(initials)}</span>`;
          mini.appendChild(div);
        }
        container.appendChild(mini);
      });
    });
  }
  toggleFolder(event) {
    event.preventDefault();
    event.stopPropagation();
    const folderEl = event.currentTarget.closest("[data-folder-id]");
    if (!folderEl)
      return;
    const collapsed = folderEl.dataset.collapsed === "true";
    const collapsedView = folderEl.querySelector("[data-folder-collapsed-view]");
    const expandedView = folderEl.querySelector("[data-folder-expanded-view]");
    const container = folderEl.querySelector("[data-folder-server-container]");
    if (collapsed) {
      folderEl.dataset.collapsed = "false";
      collapsedView.classList.add("hidden");
      if (container)
        container.classList.add("folder-grid-collapsed");
      expandedView.classList.remove("hidden");
      if (container) {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            container.classList.remove("folder-grid-collapsed");
          });
        });
      }
      const serverList = folderEl.querySelector("[data-folder-server-list]");
      if (serverList)
        this.initSingleFolderSortable(serverList);
    } else {
      if (container) {
        container.classList.add("folder-grid-collapsed");
        setTimeout(() => {
          folderEl.dataset.collapsed = "true";
          collapsedView.classList.remove("hidden");
          expandedView.classList.add("hidden");
        }, 300);
      } else {
        folderEl.dataset.collapsed = "true";
        collapsedView.classList.remove("hidden");
        expandedView.classList.add("hidden");
      }
    }
    const folderId = folderEl.dataset.folderId;
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    fetch(`/server_folders/${folderId}/toggle_collapse`, {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
    });
  }
  showFolderMenu(event) {
    event.preventDefault();
    event.stopPropagation();
    this.closeFolderMenu();
    const folderEl = event.currentTarget.closest("[data-folder-id]");
    if (!folderEl)
      return;
    const folderId = folderEl.dataset.folderId;
    const folderNameEl = folderEl.querySelector("[data-folder-name]");
    const currentName = folderNameEl ? folderNameEl.textContent.trim() : "Folder";
    this.folderMenu = document.createElement("div");
    this.folderMenu.className = "fixed z-[60] w-48 bg-gray-800 rounded-lg shadow-xl border border-gray-600 py-1.5 text-sm";
    let left = event.clientX;
    let top = event.clientY;
    if (left + 192 > window.innerWidth)
      left = window.innerWidth - 196;
    if (top + 100 > window.innerHeight)
      top = window.innerHeight - 104;
    this.folderMenu.style.left = `${left}px`;
    this.folderMenu.style.top = `${top}px`;
    const currentColor = folderEl.querySelector("[data-folder-color]")?.dataset.folderColor || "#4f545c";
    this.folderMenu.innerHTML = `
      <button data-menu-action="rename" class="w-full text-left px-3 py-1.5 text-gray-300 hover:bg-gray-700 hover:text-white transition">Rename Folder</button>
      <button data-menu-action="color" class="w-full text-left px-3 py-1.5 text-gray-300 hover:bg-gray-700 hover:text-white transition">Folder Color</button>
      <button data-menu-action="delete" class="w-full text-left px-3 py-1.5 text-red-400 hover:bg-gray-700 hover:text-red-300 transition">Delete Folder</button>
    `;
    document.body.appendChild(this.folderMenu);
    this.folderMenu.querySelector("[data-menu-action='rename']").addEventListener("click", (e) => {
      e.stopPropagation();
      this.showRenameInput(folderId, currentName, folderEl);
    });
    this.folderMenu.querySelector("[data-menu-action='color']").addEventListener("click", (e) => {
      e.stopPropagation();
      this.showColorPicker(folderId, currentColor, folderEl);
    });
    this.folderMenu.querySelector("[data-menu-action='delete']").addEventListener("click", (e) => {
      e.stopPropagation();
      this.deleteFolder(folderId, true);
      this.closeFolderMenu();
    });
    setTimeout(() => {
      document.addEventListener("click", this.boundCloseMenu);
      document.addEventListener("keydown", this.boundKeydown);
    }, 10);
  }
  showRenameInput(folderId, currentName, folderEl) {
    if (!this.folderMenu)
      return;
    this.folderMenu.innerHTML = `
      <div class="px-3 py-2">
        <label class="text-[10px] text-gray-500 uppercase font-semibold mb-1 block">Folder Name</label>
        <input type="text" value="${this.escapeAttr(currentName)}" maxlength="50"
               class="w-full bg-gray-900 border border-gray-600 rounded px-2 py-1 text-white text-sm focus:outline-none focus:border-orange-500"
               data-rename-input>
        <button class="mt-2 w-full bg-orange-600 hover:bg-orange-700 text-white text-xs font-semibold py-1 rounded transition" data-rename-save>Save</button>
      </div>
    `;
    const input = this.folderMenu.querySelector("[data-rename-input]");
    input.focus();
    input.select();
    const save2 = () => this.renameFolder(folderId, input.value.trim(), folderEl);
    this.folderMenu.querySelector("[data-rename-save]").addEventListener("click", (e) => {
      e.stopPropagation();
      save2();
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        save2();
      }
      if (e.key === "Escape") {
        this.closeFolderMenu();
      }
    });
    input.addEventListener("click", (e) => e.stopPropagation());
  }
  showColorPicker(folderId, currentColor, folderEl) {
    if (!this.folderMenu)
      return;
    const presets = [
      { color: "#4f545c", label: "Gray" },
      { color: "#5865f2", label: "Blurple" },
      { color: "#57f287", label: "Green" },
      { color: "#fee75c", label: "Yellow" },
      { color: "#eb459e", label: "Pink" },
      { color: "#ed4245", label: "Red" },
      { color: "#f47b67", label: "Orange" },
      { color: "#9b59b6", label: "Purple" }
    ];
    const swatchesHtml = presets.map((p) => {
      const ring = p.color.toLowerCase() === currentColor.toLowerCase() ? "ring-2 ring-white" : "";
      return `<button data-color-swatch="${p.color}" title="${p.label}" class="w-8 h-8 rounded-full ${ring} hover:scale-110 transition-transform" style="background-color: ${p.color}"></button>`;
    }).join("");
    this.folderMenu.innerHTML = `
      <div class="px-3 py-2">
        <label class="text-[10px] text-gray-500 uppercase font-semibold mb-2 block">Folder Color</label>
        <div class="grid grid-cols-4 gap-2 mb-2">${swatchesHtml}</div>
        <div class="flex items-center gap-2">
          <input type="color" value="${currentColor}" class="w-8 h-8 rounded cursor-pointer border-0 p-0 bg-transparent" data-custom-color>
          <span class="text-xs text-gray-400">Custom</span>
        </div>
      </div>
    `;
    const applyColor = (color) => this.applyFolderColor(folderId, color, folderEl);
    this.folderMenu.querySelectorAll("[data-color-swatch]").forEach((btn) => {
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        applyColor(btn.dataset.colorSwatch);
      });
    });
    const customInput = this.folderMenu.querySelector("[data-custom-color]");
    customInput.addEventListener("input", (e) => {
      e.stopPropagation();
      applyColor(customInput.value);
    });
    customInput.addEventListener("click", (e) => e.stopPropagation());
  }
  async applyFolderColor(folderId, color, folderEl) {
    folderEl.querySelectorAll("[data-folder-icons]").forEach((container) => {
      container.style.backgroundColor = color;
      container.dataset.folderColor = color;
    });
    const serverBg = folderEl.querySelector("[data-folder-server-bg]");
    if (serverBg) {
      serverBg.style.backgroundColor = color + "30";
      serverBg.dataset.folderServerBg = color;
    }
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    try {
      await fetch(`/server_folders/${folderId}`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({ server_folder: { color } })
      });
    } catch (e) {
    }
    this.closeFolderMenu();
  }
  async renameFolder(folderId, newName, folderEl) {
    if (!newName)
      return;
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    try {
      const response = await fetch(`/server_folders/${folderId}`, {
        method: "PATCH",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
        body: JSON.stringify({ server_folder: { name: newName } })
      });
      if (response.ok) {
        folderEl.querySelectorAll("[data-folder-name]").forEach((el) => {
          el.textContent = newName;
        });
      }
    } catch (e) {
    }
    this.closeFolderMenu();
  }
  async deleteFolder(folderId, moveServersToDom) {
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    if (moveServersToDom) {
      const folderEl = this.element.querySelector(`[data-folder-id="${folderId}"]`);
      if (folderEl) {
        const serverList = folderEl.querySelector("[data-folder-server-list]");
        if (serverList) {
          Array.from(serverList.children).forEach((serverEl) => {
            serverEl.setAttribute("data-rail-item", "server");
            this.listTarget.insertBefore(serverEl, folderEl);
          });
        }
        folderEl.remove();
      }
    }
    try {
      await fetch(`/server_folders/${folderId}`, {
        method: "DELETE",
        headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" }
      });
    } catch (e) {
    }
    this.saveOrder();
  }
  async saveOrder() {
    const items = [];
    let position = 0;
    Array.from(this.listTarget.children).forEach((child) => {
      if (child.dataset.folderId) {
        const folderServers = [];
        const serverList = child.querySelector("[data-folder-server-list]");
        if (serverList) {
          Array.from(serverList.children).forEach((serverEl, idx) => {
            if (serverEl.dataset.serverId) {
              folderServers.push({ id: serverEl.dataset.serverId, position: idx });
            }
          });
        }
        items.push({ type: "folder", id: child.dataset.folderId, position: position++, servers: folderServers });
      } else if (child.dataset.serverId) {
        items.push({ type: "server", id: child.dataset.serverId, position: position++ });
      }
    });
    const csrf = document.querySelector("meta[name=csrf-token]")?.content;
    await fetch("/reorder_servers", {
      method: "PATCH",
      headers: { "X-CSRF-Token": csrf, "Content-Type": "application/json" },
      body: JSON.stringify({ items })
    });
  }
  closeFolderMenu(event) {
    if (this.folderMenu) {
      if (event && this.folderMenu.contains(event.target))
        return;
      this.folderMenu.remove();
      this.folderMenu = null;
    }
    document.removeEventListener("click", this.boundCloseMenu);
    document.removeEventListener("keydown", this.boundKeydown);
  }
  handleKeydown(event) {
    if (event.key === "Escape") {
      this.closeFolderMenu();
    }
  }
  freezeGifs() {
    this.element.querySelectorAll(".server-icon-gif, .folder-mini-gif").forEach((el) => {
      const img = el.querySelector("[data-gif-src]");
      const canvas = el.querySelector("[data-gif-freeze]");
      if (!img || !canvas)
        return;
      const draw = () => {
        canvas.width = img.naturalWidth || 48;
        canvas.height = img.naturalHeight || 48;
        const ctx = canvas.getContext("2d");
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      };
      if (img.complete && img.naturalWidth > 0) {
        draw();
      } else {
        img.addEventListener("load", draw, { once: true });
      }
    });
  }
  escapeAttr(text) {
    return text.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
}

// app/javascript/controllers/message_actions_controller.js
class message_actions_controller_default extends Controller {
  connect() {
    this._onContextMenu = this._onContextMenu.bind(this);
    this._dismiss = this._dismiss.bind(this);
    this._isTouchDevice = false;
    this._onFirstTouch = () => {
      this._isTouchDevice = true;
    };
    this.element.addEventListener("touchstart", this._onFirstTouch, { passive: true, once: false });
    this.element.addEventListener("contextmenu", this._onContextMenu);
  }
  disconnect() {
    this.element.removeEventListener("contextmenu", this._onContextMenu);
    this.element.removeEventListener("touchstart", this._onFirstTouch);
    this._removeSheet();
  }
  _onContextMenu(e) {
    if (!this._isTouchDevice)
      return;
    const msgEl = e.target.closest("[data-message-id]");
    if (!msgEl || msgEl.dataset.systemMessage)
      return;
    const interactive = e.target.closest("a, button, video, audio, input, textarea");
    if (interactive)
      return;
    e.preventDefault();
    if (navigator.vibrate)
      navigator.vibrate(30);
    this._showSheet(msgEl);
  }
  _showSheet(msgEl) {
    this._removeSheet();
    const messageId = msgEl.dataset.messageId;
    const authorEl = msgEl.querySelector("[style*='color:']");
    const authorName = authorEl?.textContent?.trim() || "Unknown";
    const contentEl = msgEl.querySelector(".message-content");
    const rawContent = contentEl?.dataset?.rawContent || contentEl?.textContent?.trim() || "";
    const preview = rawContent.replace(/```\w*\n?/g, "").replace(/```/g, "").trim().slice(0, 80);
    const isDM = !!document.querySelector("[data-controller*='dm-message-form']");
    const backdrop = document.createElement("div");
    backdrop.className = "fixed inset-0 bg-black/50 z-[100]";
    backdrop.addEventListener("click", this._dismiss);
    const sheet = document.createElement("div");
    sheet.className = "fixed bottom-0 left-0 right-0 z-[101] bg-gray-800 rounded-t-2xl shadow-2xl border-t border-gray-700";
    sheet.innerHTML = `
      <div class="w-10 h-1 bg-gray-600 rounded-full mx-auto mt-3 mb-2"></div>
      <div class="px-4 pb-2">
        <p class="text-xs text-gray-400 truncate mb-3">${this._escapeHtml(preview)}</p>
      </div>
      <div class="px-2 pb-6 space-y-1">
        <button data-sheet-action="reply" class="flex items-center w-full px-4 py-3 text-sm text-gray-200 hover:bg-gray-700 rounded-lg active:bg-gray-600 transition">
          <svg class="w-5 h-5 mr-3 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"/></svg>
          Reply
        </button>
        ${isDM ? "" : `<button data-sheet-action="react" class="flex items-center w-full px-4 py-3 text-sm text-gray-200 hover:bg-gray-700 rounded-lg active:bg-gray-600 transition">
          <svg class="w-5 h-5 mr-3 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.828 14.828a4 4 0 01-5.656 0M9 10h.01M15 10h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>
          Add Reaction
        </button>`}
        <button data-sheet-action="copy" class="flex items-center w-full px-4 py-3 text-sm text-gray-200 hover:bg-gray-700 rounded-lg active:bg-gray-600 transition">
          <svg class="w-5 h-5 mr-3 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/></svg>
          Copy Text
        </button>
      </div>
    `;
    sheet.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-sheet-action]");
      if (!btn)
        return;
      const action = btn.dataset.sheetAction;
      if (action === "reply") {
        document.dispatchEvent(new CustomEvent("inferno:reply", {
          detail: { messageId, authorName, preview },
          bubbles: true
        }));
      } else if (action === "react") {
        document.dispatchEvent(new CustomEvent("inferno:react", {
          detail: { messageId },
          bubbles: true
        }));
      } else if (action === "copy") {
        navigator.clipboard?.writeText(rawContent).catch(() => {
        });
      }
      this._dismiss();
    });
    document.body.appendChild(backdrop);
    document.body.appendChild(sheet);
    this._backdrop = backdrop;
    this._sheet = sheet;
    document.body.style.overflow = "hidden";
  }
  _dismiss() {
    this._removeSheet();
  }
  _removeSheet() {
    if (this._backdrop) {
      this._backdrop.remove();
      this._backdrop = null;
    }
    if (this._sheet) {
      this._sheet.remove();
      this._sheet = null;
    }
    document.body.style.overflow = "";
  }
  _escapeHtml(str) {
    const div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }
}

// app/javascript/controllers/settings_sidebar_controller.js
class settings_sidebar_controller_default extends Controller {
  static targets = ["sidebar", "backdrop"];
  open() {
    this.sidebarTarget.classList.remove("hidden");
    if (this.hasBackdropTarget)
      this.backdropTarget.classList.remove("hidden");
  }
  close() {
    this.sidebarTarget.classList.add("hidden");
    if (this.hasBackdropTarget)
      this.backdropTarget.classList.add("hidden");
  }
}

// app/javascript/controllers/dirty_form_controller.js
class dirty_form_controller_default extends Controller {
  static targets = ["saveBar"];
  connect() {
    this._snapshot = this._captureState();
    this._onChange = this._checkDirty.bind(this);
    this.element.addEventListener("input", this._onChange);
    this.element.addEventListener("change", this._onChange);
  }
  disconnect() {
    this.element.removeEventListener("input", this._onChange);
    this.element.removeEventListener("change", this._onChange);
  }
  reset() {
    const elements = this.element.elements;
    for (let i = 0;i < elements.length; i++) {
      const el = elements[i];
      if (!el.name || !(el.name in this._snapshot))
        continue;
      if (el.type === "checkbox") {
        el.checked = this._snapshot[el.name];
      } else {
        el.value = this._snapshot[el.name];
      }
    }
    this._checkDirty();
  }
  _captureState() {
    const state = {};
    const elements = this.element.elements;
    for (let i = 0;i < elements.length; i++) {
      const el = elements[i];
      if (!el.name)
        continue;
      if (el.type === "checkbox") {
        state[el.name] = el.checked;
      } else {
        state[el.name] = el.value;
      }
    }
    return state;
  }
  _checkDirty() {
    const current = this._captureState();
    let dirty = false;
    for (const key in this._snapshot) {
      if (this._snapshot[key] !== current[key]) {
        dirty = true;
        break;
      }
    }
    if (this.hasSaveBarTarget) {
      if (dirty) {
        this.saveBarTarget.style.display = "";
        requestAnimationFrame(() => {
          this.saveBarTarget.style.opacity = "1";
          this.saveBarTarget.style.transform = "translateY(0)";
        });
      } else {
        this.saveBarTarget.style.opacity = "0";
        this.saveBarTarget.style.transform = "translateY(100%)";
        setTimeout(() => {
          if (!this._isDirty())
            this.saveBarTarget.style.display = "none";
        }, 200);
      }
    }
  }
  _isDirty() {
    const current = this._captureState();
    for (const key in this._snapshot) {
      if (this._snapshot[key] !== current[key])
        return true;
    }
    return false;
  }
}

// app/javascript/controllers/frame_loading_controller.js
class frame_loading_controller_default extends Controller {
  connect() {
    this._onBeforeFetch = this._handleBeforeFetch.bind(this);
    document.addEventListener("turbo:before-fetch-request", this._onBeforeFetch);
  }
  disconnect() {
    document.removeEventListener("turbo:before-fetch-request", this._onBeforeFetch);
  }
  _handleBeforeFetch(e) {
    if (e.target.id !== "main-content")
      return;
    const method = e.detail?.fetchOptions?.method;
    if (method && method.toUpperCase() !== "GET")
      return;
    this._showSkeleton(e.target);
  }
  _showSkeleton(frame) {
    const msgs = Array.from({ length: 6 }, (_, i) => {
      const nameW = ["w-20", "w-28", "w-24", "w-32", "w-20", "w-36"][i];
      const lineW = ["w-64 sm:w-80", "w-48 sm:w-64", "w-56 sm:w-72", "w-40 sm:w-56", "w-72 sm:w-96", "w-44 sm:w-60"][i];
      return `<div class="flex items-start gap-3 px-4">
        <div class="w-10 h-10 bg-gray-600 rounded-full shrink-0"></div>
        <div class="space-y-2 flex-1 min-w-0">
          <div class="flex items-center gap-2">
            <div class="h-3.5 bg-gray-600 rounded ${nameW}"></div>
            <div class="h-3 bg-gray-600/40 rounded w-10"></div>
          </div>
          <div class="h-3.5 bg-gray-600/30 rounded ${lineW} max-w-full"></div>
        </div>
      </div>`;
    }).join("");
    frame.innerHTML = `
      <div class="flex flex-col flex-1 min-h-0 animate-pulse">
        <div class="flex items-center h-12 px-4 border-b border-gray-900 shrink-0">
          <div class="w-5 h-5 bg-gray-600 rounded mr-2"></div>
          <div class="h-4 bg-gray-600 rounded w-28"></div>
        </div>
        <div class="flex-1 overflow-hidden flex flex-col justify-end py-4 space-y-5">
          ${msgs}
        </div>
        <div class="px-4 pb-4 pt-2">
          <div class="h-11 bg-gray-600/30 rounded-lg"></div>
        </div>
      </div>`;
  }
}

// app/javascript/application.js
var application = Application.start();
setConfirmMethod((message) => {
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "fixed inset-0 z-[100] flex items-center justify-center bg-black/60";
    overlay.innerHTML = `
      <div class="bg-gray-800 rounded-lg shadow-2xl border border-gray-700 w-full max-w-md mx-4 overflow-hidden">
        <div class="px-5 pt-5 pb-4">
          <h3 class="text-lg font-semibold text-white mb-2">Are you sure?</h3>
          <p class="text-sm text-gray-300">${message.replace(/</g, "&lt;").replace(/>/g, "&gt;")}</p>
        </div>
        <div class="flex justify-end gap-3 px-5 py-4 bg-gray-850 bg-gray-900/50">
          <button data-action="cancel" class="px-4 py-2 text-sm font-medium text-gray-300 hover:text-white hover:underline cursor-pointer">Cancel</button>
          <button data-action="confirm" class="px-4 py-2 text-sm font-medium bg-red-600 hover:bg-red-700 text-white rounded transition cursor-pointer">Confirm</button>
        </div>
      </div>
    `;
    const cleanup = (result) => {
      overlay.remove();
      resolve(result);
    };
    overlay.addEventListener("click", (e) => {
      if (e.target === overlay)
        cleanup(false);
    });
    overlay.querySelector('[data-action="cancel"]').addEventListener("click", () => cleanup(false));
    overlay.querySelector('[data-action="confirm"]').addEventListener("click", () => cleanup(true));
    document.addEventListener("keydown", function handler(e) {
      if (e.key === "Escape") {
        document.removeEventListener("keydown", handler);
        cleanup(false);
      }
      if (e.key === "Enter") {
        document.removeEventListener("keydown", handler);
        cleanup(true);
      }
    });
    document.body.appendChild(overlay);
    overlay.querySelector('[data-action="confirm"]').focus();
  });
});
try {
  const stored = localStorage.getItem("_emojiMap");
  if (stored) {
    window._emojiMap = JSON.parse(stored);
    window._emojiPUA = JSON.parse(localStorage.getItem("_emojiPUA") || "{}");
    window._emojiReverse = JSON.parse(localStorage.getItem("_emojiReverse") || "{}");
    window._nextPUA = parseInt(localStorage.getItem("_nextPUA") || "0") || 57344;
  }
} catch (e) {
}
application.register("message-form", message_form_controller_default);
application.register("scroll-position", scroll_position_controller_default);
application.register("toast", toast_controller_default);
application.register("unified-picker", unified_picker_controller_default);
application.register("gif-save", gif_save_controller_default);
application.register("dropdown", dropdown_controller_default);
application.register("server-members", server_members_controller_default);
application.register("profile-card", profile_card_controller_default);
application.register("appearance", appearance_controller_default);
application.register("mention-autocomplete", mention_autocomplete_controller_default);
application.register("notification-badge", notification_badge_controller_default);
application.register("member-context", member_context_controller_default);
application.register("category-collapse", category_collapse_controller_default);
application.register("channel-sidebar", channel_sidebar_controller_default);
application.register("channel-reorder", channel_reorder_controller_default);
application.register("image-preview", image_preview_controller_default);
application.register("mobile-nav", mobile_nav_controller_default);
application.register("banner-editor", banner_editor_controller_default);
application.register("dm-message-form", dm_message_form_controller_default);
application.register("invite-menu", invite_menu_controller_default);
application.register("video-player", video_player_controller_default);
application.register("nostr-key-export", nostr_key_export_controller_default);
application.register("role-editor", role_editor_controller_default);
application.register("member-roles", member_roles_controller_default);
application.register("server-rail", server_rail_controller_default);
application.register("message-actions", message_actions_controller_default);
application.register("settings-sidebar", settings_sidebar_controller_default);
application.register("dirty-form", dirty_form_controller_default);
application.register("frame-loading", frame_loading_controller_default);

//# debugId=DAFE62EC2392F2C764756E2164756E21
