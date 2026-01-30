import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import {
  type ChatSession,
  type ChatMessage,
  type ChatSettings,
  type ModelStatus,
  type ChatAttachment,
  type ChatArtifact,
  type ArtifactVersion,
  createChatSession,
  createChatMessage,
  DEFAULT_CHAT_SETTINGS,
} from '@/types/chat';
import { useSettingsStore } from './settingsStore';

const STORAGE_KEY = 'leaxer-chat-store';

interface ChatState {
  // Sessions
  sessions: ChatSession[];
  activeSessionId: string | null;
  // Track which sessions have full content loaded (for lazy loading)
  loadedSessionIds: Set<string>;
  // Track sessions currently being loaded
  loadingSessionIds: Set<string>;

  // Generation state
  isGenerating: boolean;
  streamingContent: string;

  // Connection state
  isConnected: boolean;

  // Model state
  selectedModel: string | null;
  modelStatus: ModelStatus;

  // Thinking mode
  thinkingEnabled: boolean;

  // Internet/web search mode
  internetEnabled: boolean;

  // Artifact/document creation mode
  artifactEnabled: boolean;

  // Search settings
  searchProvider: string;
  searchMaxResults: number;

  // Chat status for status pill
  chatStatus: 'idle' | 'searching' | 'thinking' | 'generating' | 'creating';
  chatStatusQuery: string | null;

  // File attach trigger (incremented to trigger file picker)
  fileAttachTrigger: number;

  // LLM server state
  llmServerStatus: 'idle' | 'loading' | 'ready' | 'error' | 'restarting';
  llmServerLogs: Array<{ line: string; timestamp: number }>;
  llmServerError: string | null;

  // Session actions
  createSession: (name?: string) => string;
  createBranchedSession: (fromSessionId: string, name: string, userMessage: ChatMessage) => string;
  deleteSession: (id: string) => void;
  setActiveSession: (id: string | null) => void;
  renameSession: (id: string, name: string) => void;
  getActiveSession: () => ChatSession | null;
  loadSessionContent: (sessionId: string) => Promise<void>;
  startNewChat: () => void;

  // Message actions
  addMessage: (sessionId: string, role: ChatMessage['role'], content: string, model?: string, attachments?: ChatAttachment[]) => string;
  updateMessage: (sessionId: string, messageId: string, content: string) => void;
  deleteMessage: (sessionId: string, messageId: string) => void;
  setMessageStreaming: (sessionId: string, messageId: string, isStreaming: boolean) => void;
  setMessageHiding: (sessionId: string, messageId: string, isHiding: boolean) => void;
  appendToMessage: (sessionId: string, messageId: string, content: string) => void;
  setMessageFollowUps: (sessionId: string, messageId: string, followUps: string[]) => void;
  setMessageReferences: (sessionId: string, messageId: string, references: Array<{ index: number; title: string; url: string; description?: string; image?: string; site_name?: string; favicon?: string }>) => void;

  // Generation actions
  setIsGenerating: (isGenerating: boolean) => void;
  setStreamingContent: (content: string) => void;
  appendStreamingContent: (content: string) => void;
  clearStreamingContent: () => void;

  // Connection actions
  setConnected: (connected: boolean) => void;

  // Model actions
  setSelectedModel: (model: string | null) => void;
  setModelStatus: (status: ModelStatus) => void;

  // Thinking actions
  setThinkingEnabled: (enabled: boolean) => void;

  // Internet actions
  setInternetEnabled: (enabled: boolean) => void;

  // Artifact actions
  setArtifactEnabled: (enabled: boolean) => void;
  setMessageArtifact: (sessionId: string, messageId: string, artifact: ChatArtifact) => void;
  updateMessageArtifact: (sessionId: string, messageId: string, updates: Partial<ChatArtifact>) => void;
  appendToArtifact: (sessionId: string, messageId: string, content: string) => void;
  moveArtifactToMessage: (sessionId: string, fromMessageId: string, toMessageId: string) => void;
  removeMessageArtifact: (sessionId: string, messageId: string) => void;

  // Search settings actions
  setSearchProvider: (provider: string) => void;
  setSearchMaxResults: (maxResults: number) => void;

  // Chat status actions
  setChatStatus: (status: 'idle' | 'searching' | 'thinking' | 'generating' | 'creating', query?: string | null) => void;

  // File attach trigger
  triggerFileAttach: () => void;

  // LLM server actions
  setLlmServerStatus: (status: 'idle' | 'loading' | 'ready' | 'error' | 'restarting', error?: string) => void;
  addLlmServerLog: (line: string, timestamp: number) => void;
  clearLlmServerLogs: () => void;

  // Settings actions
  updateSessionSettings: (sessionId: string, settings: Partial<ChatSettings>) => void;
  updateSessionModel: (sessionId: string, model: string | null) => void;

  // Persistence actions
  loadSessionsFromBackend: () => Promise<void>;
  saveSessionToBackend: (sessionId: string) => Promise<void>;
  deleteSessionFromBackend: (sessionId: string) => Promise<void>;
}

export const useChatStore = create<ChatState>()(
  persist(
    (set, get) => ({
      // Initial state
      sessions: [],
      activeSessionId: null,
      loadedSessionIds: new Set<string>(),
      loadingSessionIds: new Set<string>(),
      isGenerating: false,
      streamingContent: '',
      isConnected: false,
      selectedModel: null,
      modelStatus: 'idle',
      thinkingEnabled: false,
      internetEnabled: false,
      artifactEnabled: false,
      searchProvider: 'duckduckgo',
      searchMaxResults: 3,
      chatStatus: 'idle',
      chatStatusQuery: null,
      fileAttachTrigger: 0,
      llmServerStatus: 'idle',
      llmServerLogs: [],
      llmServerError: null,

      // Session actions
      createSession: (name?: string) => {
        const session = createChatSession(undefined, name);
        set((state) => ({
          sessions: [session, ...state.sessions],
          activeSessionId: session.id,
          // Mark new session as loaded (it has no messages to fetch)
          loadedSessionIds: new Set([...state.loadedSessionIds, session.id]),
        }));
        // Save to backend
        get().saveSessionToBackend(session.id);
        return session.id;
      },

      createBranchedSession: (fromSessionId: string, name: string, userMessage: ChatMessage) => {
        const session = createChatSession(undefined, name);
        // Copy the user message with a new ID
        const copiedMessage = createChatMessage(
          userMessage.role,
          userMessage.content,
          false,
          undefined,
          userMessage.attachments
        );
        // Set branchedFrom and add the copied message
        const branchedSession: ChatSession = {
          ...session,
          branchedFrom: fromSessionId,
          messages: [copiedMessage],
        };
        set((state) => ({
          sessions: [branchedSession, ...state.sessions],
          activeSessionId: branchedSession.id,
          loadedSessionIds: new Set([...state.loadedSessionIds, branchedSession.id]),
        }));
        // Save to backend
        get().saveSessionToBackend(branchedSession.id);
        return branchedSession.id;
      },

      deleteSession: (id: string) => {
        set((state) => {
          const newSessions = state.sessions.filter((s) => s.id !== id);
          const newActiveId =
            state.activeSessionId === id
              ? newSessions.length > 0
                ? newSessions[0].id
                : null
              : state.activeSessionId;

          // Clean up loaded/loading sets
          const newLoadedIds = new Set(state.loadedSessionIds);
          newLoadedIds.delete(id);
          const newLoadingIds = new Set(state.loadingSessionIds);
          newLoadingIds.delete(id);

          return {
            sessions: newSessions,
            activeSessionId: newActiveId,
            loadedSessionIds: newLoadedIds,
            loadingSessionIds: newLoadingIds,
          };
        });
        // Delete from backend
        get().deleteSessionFromBackend(id);
      },

      setActiveSession: (id: string | null) => {
        set({ activeSessionId: id });
        // Lazy load session content if needed
        if (id) {
          const state = get();
          if (!state.loadedSessionIds.has(id) && !state.loadingSessionIds.has(id)) {
            get().loadSessionContent(id);
          }
        }
      },

      renameSession: (id: string, name: string) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === id ? { ...s, name, updated_at: Date.now() } : s
          ),
        }));
        // Save to backend
        get().saveSessionToBackend(id);
      },

      getActiveSession: () => {
        const state = get();
        if (!state.activeSessionId) return null;
        return state.sessions.find((s) => s.id === state.activeSessionId) || null;
      },

      loadSessionContent: async (sessionId: string) => {
        const state = get();
        // Already loaded or loading
        if (state.loadedSessionIds.has(sessionId) || state.loadingSessionIds.has(sessionId)) {
          return;
        }

        // Mark as loading
        set((s) => ({
          loadingSessionIds: new Set([...s.loadingSessionIds, sessionId]),
        }));

        try {
          const apiBaseUrl = useSettingsStore.getState().getApiBaseUrl();
          const response = await fetch(`${apiBaseUrl}/api/chats/${sessionId}`);

          if (response.ok) {
            const fullSession = await response.json();
            // Ensure settings have defaults
            fullSession.settings = { ...DEFAULT_CHAT_SETTINGS, ...fullSession.settings };

            set((s) => {
              // Update the session with full content
              const updatedSessions = s.sessions.map((session) =>
                session.id === sessionId
                  ? { ...session, messages: fullSession.messages || [], settings: fullSession.settings }
                  : session
              );

              // Mark as loaded, remove from loading
              const newLoadedIds = new Set([...s.loadedSessionIds, sessionId]);
              const newLoadingIds = new Set(s.loadingSessionIds);
              newLoadingIds.delete(sessionId);

              return {
                sessions: updatedSessions,
                loadedSessionIds: newLoadedIds,
                loadingSessionIds: newLoadingIds,
              };
            });
          }
        } catch (err) {
          console.error(`Failed to load session content for ${sessionId}:`, err);
          // Remove from loading on error
          set((s) => {
            const newLoadingIds = new Set(s.loadingSessionIds);
            newLoadingIds.delete(sessionId);
            return { loadingSessionIds: newLoadingIds };
          });
        }
      },

      startNewChat: () => {
        const state = get();

        // Check if current active session is empty (no messages)
        if (state.activeSessionId) {
          const activeSession = state.sessions.find((s) => s.id === state.activeSessionId);
          if (activeSession && activeSession.messages.length === 0) {
            // Already on an empty chat, do nothing
            return;
          }
        }

        // Check if the most recent session (first in list) is empty
        if (state.sessions.length > 0) {
          const firstSession = state.sessions[0];
          if (firstSession.messages.length === 0) {
            // Switch to the existing empty session
            set({ activeSessionId: firstSession.id });
            return;
          }
        }

        // Create a new session
        get().createSession();
      },

      // Message actions
      addMessage: (sessionId: string, role: ChatMessage['role'], content: string, model?: string, attachments?: ChatAttachment[]) => {
        const message = createChatMessage(role, content, role === 'assistant', model, attachments);
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: [...s.messages, message],
                  updated_at: Date.now(),
                }
              : s
          ),
        }));
        return message.id;
      },

      updateMessage: (sessionId: string, messageId: string, content: string) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId ? { ...m, content } : m
                  ),
                  updated_at: Date.now(),
                }
              : s
          ),
        }));
      },

      deleteMessage: (sessionId: string, messageId: string) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.filter((m) => m.id !== messageId),
                  updated_at: Date.now(),
                }
              : s
          ),
        }));
      },

      setMessageStreaming: (sessionId: string, messageId: string, isStreaming: boolean) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId ? { ...m, isStreaming } : m
                  ),
                }
              : s
          ),
        }));
      },

      setMessageHiding: (sessionId: string, messageId: string, isHiding: boolean) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId ? { ...m, isHiding } : m
                  ),
                }
              : s
          ),
        }));
      },

      appendToMessage: (sessionId: string, messageId: string, content: string) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId ? { ...m, content: m.content + content } : m
                  ),
                }
              : s
          ),
        }));
      },

      setMessageFollowUps: (sessionId: string, messageId: string, followUps: string[]) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId ? { ...m, followUps } : m
                  ),
                }
              : s
          ),
        }));
      },

      setMessageReferences: (sessionId: string, messageId: string, references: Array<{ index: number; title: string; url: string; description?: string; image?: string; site_name?: string; favicon?: string }>) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId ? { ...m, references } : m
                  ),
                }
              : s
          ),
        }));
      },

      // Generation actions
      setIsGenerating: (isGenerating: boolean) => {
        set({ isGenerating });
      },

      setStreamingContent: (content: string) => {
        set({ streamingContent: content });
      },

      appendStreamingContent: (content: string) => {
        set((state) => ({
          streamingContent: state.streamingContent + content,
        }));
      },

      clearStreamingContent: () => {
        set({ streamingContent: '' });
      },

      // Connection actions
      setConnected: (connected: boolean) => {
        set({ isConnected: connected });
      },

      // Model actions
      setSelectedModel: (model: string | null) => {
        set({ selectedModel: model });
        // Update active session's model
        const state = get();
        if (state.activeSessionId && model) {
          get().updateSessionModel(state.activeSessionId, model);
        }
      },

      setModelStatus: (status: ModelStatus) => {
        set({ modelStatus: status });
      },

      setThinkingEnabled: (enabled: boolean) => {
        set({ thinkingEnabled: enabled });
      },

      setInternetEnabled: (enabled: boolean) => {
        set({ internetEnabled: enabled });
      },

      setArtifactEnabled: (enabled: boolean) => {
        set({ artifactEnabled: enabled });
      },

      setMessageArtifact: (sessionId: string, messageId: string, artifact: ChatArtifact) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId ? { ...m, artifact } : m
                  ),
                }
              : s
          ),
        }));
      },

      updateMessageArtifact: (sessionId: string, messageId: string, updates: Partial<ChatArtifact>) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId && m.artifact
                      ? { ...m, artifact: { ...m.artifact, ...updates } }
                      : m
                  ),
                }
              : s
          ),
        }));
      },

      appendToArtifact: (sessionId: string, messageId: string, content: string) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) =>
                    m.id === messageId && m.artifact
                      ? { ...m, artifact: { ...m.artifact, content: m.artifact.content + content } }
                      : m
                  ),
                }
              : s
          ),
        }));
      },

      moveArtifactToMessage: (sessionId: string, fromMessageId: string, toMessageId: string) => {
        set((state) => {
          // Guard: don't move to same message
          if (fromMessageId === toMessageId) return state;

          const session = state.sessions.find((s) => s.id === sessionId);
          if (!session) return state;

          const fromMessage = session.messages.find((m) => m.id === fromMessageId);
          if (!fromMessage?.artifact) return state;

          const existingArtifact = fromMessage.artifact;

          // Create a new version entry for the existing content
          const newVersion: ArtifactVersion = {
            version: (existingArtifact.currentVersion || 1),
            title: existingArtifact.title,
            content: existingArtifact.content,
            created_at: existingArtifact.created_at,
          };

          // Combine existing versions with the new one
          const allVersions = [...(existingArtifact.versions || []), newVersion];

          // Create new artifact for target message (content will be streamed)
          const newArtifact: ChatArtifact = {
            id: existingArtifact.id,
            title: existingArtifact.title,
            content: '', // Will be streamed
            created_at: Date.now(),
            sources: existingArtifact.sources,
            status: 'generating',
            versions: allVersions,
            currentVersion: allVersions.length + 1,
          };

          return {
            sessions: state.sessions.map((s) =>
              s.id === sessionId
                ? {
                    ...s,
                    messages: s.messages.map((m) => {
                      if (m.id === fromMessageId) {
                        // Remove artifact from source message
                        const { artifact: _artifact, ...rest } = m;
                        return rest;
                      }
                      if (m.id === toMessageId) {
                        // Add artifact to target message
                        return { ...m, artifact: newArtifact };
                      }
                      return m;
                    }),
                  }
                : s
            ),
          };
        });
      },

      removeMessageArtifact: (sessionId: string, messageId: string) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  messages: s.messages.map((m) => {
                    if (m.id === messageId && m.artifact) {
                      const { artifact: _artifact, ...rest } = m;
                      return rest;
                    }
                    return m;
                  }),
                }
              : s
          ),
        }));
      },

      setSearchProvider: (provider: string) => {
        set({ searchProvider: provider });
      },

      setSearchMaxResults: (maxResults: number) => {
        set({ searchMaxResults: maxResults });
      },

      setChatStatus: (status: 'idle' | 'searching' | 'thinking' | 'generating' | 'creating', query?: string | null) => {
        set({ chatStatus: status, chatStatusQuery: query ?? null });
      },

      triggerFileAttach: () => {
        set((state) => ({ fileAttachTrigger: state.fileAttachTrigger + 1 }));
      },

      // LLM server actions
      setLlmServerStatus: (status, error) => {
        set({
          llmServerStatus: status,
          llmServerError: error ?? null,
        });
        // Clear logs when server becomes ready
        if (status === 'ready') {
          set({ llmServerLogs: [] });
        }
      },

      addLlmServerLog: (line, timestamp) => {
        set((state) => ({
          llmServerLogs: [...state.llmServerLogs.slice(-99), { line, timestamp }], // Keep last 100 lines
        }));
      },

      clearLlmServerLogs: () => {
        set({ llmServerLogs: [] });
      },

      // Settings actions
      updateSessionSettings: (sessionId: string, settings: Partial<ChatSettings>) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? {
                  ...s,
                  settings: { ...s.settings, ...settings },
                  updated_at: Date.now(),
                }
              : s
          ),
        }));
        get().saveSessionToBackend(sessionId);
      },

      updateSessionModel: (sessionId: string, model: string | null) => {
        set((state) => ({
          sessions: state.sessions.map((s) =>
            s.id === sessionId
              ? { ...s, model, updated_at: Date.now() }
              : s
          ),
        }));
      },

      // Persistence actions
      loadSessionsFromBackend: async () => {
        try {
          const apiBaseUrl = useSettingsStore.getState().getApiBaseUrl();
          const response = await fetch(`${apiBaseUrl}/api/chats`);

          if (!response.ok) {
            console.error('Failed to load chat sessions:', response.statusText);
            return;
          }

          const data = await response.json();
          const summaries = data.sessions || [];

          // Create placeholder sessions from summaries (lazy load content later)
          const sessions: ChatSession[] = summaries.map((summary: { id: string; name: string; modified_at?: string }) => ({
            id: summary.id,
            name: summary.name || 'Untitled',
            messages: [], // Empty - will be loaded when session is selected
            created_at: summary.modified_at ? new Date(summary.modified_at).getTime() : Date.now(),
            updated_at: summary.modified_at ? new Date(summary.modified_at).getTime() : Date.now(),
            model: null,
            settings: { ...DEFAULT_CHAT_SETTINGS },
          }));

          // Sort by updated_at descending
          sessions.sort((a, b) => b.updated_at - a.updated_at);

          // Reset loaded/loading sets since we're loading fresh summaries
          set({
            sessions,
            loadedSessionIds: new Set<string>(),
            loadingSessionIds: new Set<string>(),
          });

          // Always start with a new chat (or reuse existing empty one)
          get().startNewChat();
        } catch (err) {
          console.error('Failed to load chat sessions:', err);
        }
      },

      saveSessionToBackend: async (sessionId: string) => {
        const state = get();
        const session = state.sessions.find((s) => s.id === sessionId);
        if (!session) return;

        try {
          const apiBaseUrl = useSettingsStore.getState().getApiBaseUrl();
          await fetch(`${apiBaseUrl}/api/chats`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(session),
          });
        } catch (err) {
          console.error('Failed to save chat session:', err);
        }
      },

      deleteSessionFromBackend: async (sessionId: string) => {
        try {
          const apiBaseUrl = useSettingsStore.getState().getApiBaseUrl();
          await fetch(`${apiBaseUrl}/api/chats/${sessionId}`, {
            method: 'DELETE',
          });
        } catch (err) {
          console.error('Failed to delete chat session:', err);
        }
      },
    }),
    {
      name: STORAGE_KEY,
      partialize: (state) => ({
        // Persist sessions locally as well for offline access
        sessions: state.sessions,
        // Don't persist activeSessionId - always start with new chat
        selectedModel: state.selectedModel,
        thinkingEnabled: state.thinkingEnabled,
        internetEnabled: state.internetEnabled,
        artifactEnabled: state.artifactEnabled,
        searchProvider: state.searchProvider,
        searchMaxResults: state.searchMaxResults,
        // Don't persist: generation state, model status, loadedSessionIds, loadingSessionIds (Sets don't serialize)
      }),
    }
  )
);
