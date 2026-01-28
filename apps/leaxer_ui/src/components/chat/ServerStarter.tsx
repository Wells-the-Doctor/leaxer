import { memo, useState, useCallback, useEffect, useRef, useMemo } from 'react';
import { createPortal } from 'react-dom';
import { AlertTriangle, Play, Loader2, ChevronDown, ChevronUp, Download, Check, Sparkles } from 'lucide-react';
import { cn } from '@/lib/utils';
import { useChatStore } from '@/stores/chatStore';
import { useSettingsStore } from '@/stores/settingsStore';
import { useDownloadStore } from '@/stores/downloadStore';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';

interface LLMModel {
  name: string;
  path: string;
  size?: string;
}

interface ServerStarterProps {
  onStart: (model: string) => Promise<void>;
  isStarting: boolean;
}

export const ServerStarter = memo(({ onStart, isStarting }: ServerStarterProps) => {
  const [isModelOpen, setIsModelOpen] = useState(false);
  const [models, setModels] = useState<LLMModel[]>([]);
  const [loadingModels, setLoadingModels] = useState(false);
  const [logsExpanded, setLogsExpanded] = useState(true);
  const logsEndRef = useRef<HTMLDivElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);
  const modelButtonRef = useRef<HTMLButtonElement>(null);
  const [dropdownPosition, setDropdownPosition] = useState({ top: 0, left: 0, width: 0 });

  const selectedModel = useChatStore((s) => s.selectedModel);
  const setSelectedModel = useChatStore((s) => s.setSelectedModel);
  const llmServerLogs = useChatStore((s) => s.llmServerLogs);
  const llmServerError = useChatStore((s) => s.llmServerError);
  const getApiBaseUrl = useSettingsStore((s) => s.getApiBaseUrl);

  // Get just the model name for display
  const selectedModelName = useMemo(() => {
    if (!selectedModel) return null;
    const model = models.find((m) => m.path === selectedModel);
    return model?.name || selectedModel.split('/').pop();
  }, [selectedModel, models]);

  // Fetch models on mount
  useEffect(() => {
    const fetchModels = async () => {
      setLoadingModels(true);
      try {
        const apiBaseUrl = getApiBaseUrl();
        const response = await fetch(`${apiBaseUrl}/api/models/llms`);
        if (response.ok) {
          const data = await response.json();
          const llmModels: LLMModel[] = (data.models || []).map((m: { name: string; path: string; size_human?: string }) => ({
            name: m.name,
            path: m.path,
            size: m.size_human,
          }));
          setModels(llmModels);

          // Auto-select first model if none selected
          if (!selectedModel && llmModels.length > 0) {
            setSelectedModel(llmModels[0].path);
          }
        }
      } catch (err) {
        console.error('Failed to fetch LLM models:', err);
      } finally {
        setLoadingModels(false);
      }
    };
    fetchModels();
  }, [getApiBaseUrl, selectedModel, setSelectedModel]);

  // Close dropdown when clicking outside
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (
        dropdownRef.current &&
        !dropdownRef.current.contains(event.target as Node) &&
        modelButtonRef.current &&
        !modelButtonRef.current.contains(event.target as Node)
      ) {
        setIsModelOpen(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Calculate dropdown position when opening
  useEffect(() => {
    if (isModelOpen && modelButtonRef.current) {
      const rect = modelButtonRef.current.getBoundingClientRect();
      setDropdownPosition({
        top: rect.bottom + 8,
        left: rect.left,
        width: rect.width,
      });
    }
  }, [isModelOpen]);

  // Auto-scroll logs
  useEffect(() => {
    if (logsExpanded && logsEndRef.current) {
      logsEndRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [llmServerLogs, logsExpanded]);

  const handleSelectModel = useCallback((model: LLMModel) => {
    setSelectedModel(model.path);
    setIsModelOpen(false);
  }, [setSelectedModel]);

  const handleStart = useCallback(async () => {
    if (!selectedModel || isStarting) return;
    await onStart(selectedModel);
  }, [selectedModel, isStarting, onStart]);

  return (
    <div
      className="flex flex-col gap-4 p-6 rounded-2xl backdrop-blur-xl"
      style={{
        background: 'rgba(255, 255, 255, 0.06)',
        boxShadow: '0 8px 32px rgba(0, 0, 0, 0.3), inset 0 1px 0 rgba(255, 255, 255, 0.1)',
      }}
    >
      {/* Warning header */}
      <div className="flex items-center gap-3">
        <div
          className="flex items-center justify-center w-10 h-10 rounded-full"
          style={{ background: 'rgba(250, 179, 135, 0.15)' }}
        >
          <AlertTriangle className="w-5 h-5" style={{ color: 'var(--color-peach)' }} />
        </div>
        <div>
          <h3 className="font-medium" style={{ color: 'var(--color-text)' }}>
            LLM Server Not Running
          </h3>
          <p className="text-sm" style={{ color: 'var(--color-text-secondary)' }}>
            Select a model and start the server to begin chatting
          </p>
        </div>
      </div>

      {/* Model selector and start button */}
      <div className="flex gap-3">
        {/* Model selector */}
        <div className="relative flex-1">
          <TooltipProvider delayDuration={300}>
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  ref={modelButtonRef}
                  onClick={() => setIsModelOpen(!isModelOpen)}
                  disabled={isStarting}
                  className={cn(
                    'flex items-center justify-between w-full px-4 py-3 rounded-xl transition-all duration-200',
                    'hover:bg-white/10',
                    isStarting && 'opacity-50 cursor-not-allowed'
                  )}
                  style={{
                    background: 'rgba(255, 255, 255, 0.08)',
                    color: 'var(--color-text)',
                  }}
                >
                  <div className="flex items-center gap-2">
                    <Sparkles className="w-4 h-4" style={{ color: 'var(--color-text-secondary)' }} />
                    <span className="text-sm">
                      {loadingModels ? 'Loading models...' : selectedModelName || 'Select model'}
                    </span>
                  </div>
                  <ChevronDown className="w-4 h-4" style={{ color: 'var(--color-text-secondary)' }} />
                </button>
              </TooltipTrigger>
              <TooltipContent side="top">Select LLM model</TooltipContent>
            </Tooltip>
          </TooltipProvider>

          {/* Dropdown - rendered via portal */}
          {isModelOpen && createPortal(
            <div
              ref={dropdownRef}
              className="fixed py-1.5 rounded-xl min-w-[220px] max-h-64 overflow-y-auto backdrop-blur-xl z-50"
              style={{
                top: dropdownPosition.top,
                left: dropdownPosition.left,
                width: Math.max(dropdownPosition.width, 280),
                background: 'rgba(255, 255, 255, 0.08)',
                boxShadow: '0 8px 32px rgba(0, 0, 0, 0.3), inset 0 1px 0 rgba(255, 255, 255, 0.1)',
              }}
            >
              {loadingModels ? (
                <div
                  className="flex items-center justify-center gap-2 px-3 py-4 text-xs"
                  style={{ color: 'var(--color-text-secondary)' }}
                >
                  <Loader2 className="w-4 h-4 animate-spin" />
                  Loading models...
                </div>
              ) : models.length === 0 ? (
                <div className="px-3 py-3 text-xs text-center">
                  <div style={{ color: 'var(--color-text-secondary)' }}>
                    No LLM models found.
                    <br />
                    <span className="opacity-70">Add .gguf files to models/llm/</span>
                  </div>
                  <button
                    onClick={() => {
                      setIsModelOpen(false);
                      useDownloadStore.getState().openModalToCategory('llms');
                    }}
                    className="flex items-center justify-center gap-2 w-full mt-2 px-3 py-1.5 rounded-lg transition-colors hover:bg-white/10"
                    style={{ color: 'var(--color-accent)' }}
                  >
                    <Download className="w-4 h-4" />
                    <span>Download models</span>
                  </button>
                </div>
              ) : (
                <>
                  {models.map((model) => {
                    const isSelected = model.path === selectedModel;
                    return (
                      <button
                        key={model.path}
                        onClick={() => handleSelectModel(model)}
                        className={cn(
                          'flex items-center gap-2 w-[calc(100%-12px)] mx-1.5 px-3 py-2 text-sm text-left rounded-lg transition-colors',
                          'hover:bg-white/10'
                        )}
                        style={{
                          color: 'var(--color-text)',
                          opacity: isSelected ? 1 : 0.7,
                        }}
                      >
                        <div className="flex-1 min-w-0">
                          <div className="truncate">{model.name}</div>
                          {model.size && (
                            <div
                              className="text-xs"
                              style={{ color: 'var(--color-text-muted)' }}
                            >
                              {model.size}
                            </div>
                          )}
                        </div>
                        {isSelected && (
                          <Check
                            className="w-4 h-4 flex-shrink-0"
                            style={{ color: 'var(--color-accent)' }}
                          />
                        )}
                      </button>
                    );
                  })}
                  {/* Divider and Get more button */}
                  <div className="mx-1.5 my-1 border-t border-white/10" />
                  <button
                    onClick={() => {
                      setIsModelOpen(false);
                      useDownloadStore.getState().openModalToCategory('llms');
                    }}
                    className="flex items-center gap-2 w-[calc(100%-12px)] mx-1.5 px-3 py-2 text-xs text-left rounded-lg transition-colors hover:bg-white/10"
                    style={{ color: 'var(--color-text-secondary)' }}
                  >
                    <Download className="w-4 h-4" />
                    <span>Get more models...</span>
                  </button>
                </>
              )}
            </div>,
            document.body
          )}
        </div>

        {/* Start button */}
        <TooltipProvider delayDuration={300}>
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                onClick={handleStart}
                disabled={!selectedModel || isStarting}
                className={cn(
                  'flex items-center gap-2 px-6 py-3 rounded-xl font-medium transition-all duration-200',
                  'hover:scale-105 active:scale-100',
                  (!selectedModel || isStarting) && 'opacity-50 cursor-not-allowed hover:scale-100'
                )}
                style={{
                  background: 'var(--color-green)',
                  color: 'var(--color-base)',
                }}
              >
                {isStarting ? (
                  <>
                    <Loader2 className="w-5 h-5 animate-spin" />
                    <span>Starting...</span>
                  </>
                ) : (
                  <>
                    <Play className="w-5 h-5" />
                    <span>Start Server</span>
                  </>
                )}
              </button>
            </TooltipTrigger>
            <TooltipContent side="top">
              {!selectedModel ? 'Select a model first' : 'Start the LLM server'}
            </TooltipContent>
          </Tooltip>
        </TooltipProvider>
      </div>

      {/* Error message */}
      {llmServerError && (
        <div
          className="px-4 py-3 rounded-xl text-sm"
          style={{
            background: 'rgba(243, 139, 168, 0.15)',
            color: 'var(--color-red)',
          }}
        >
          {llmServerError}
        </div>
      )}

      {/* Startup logs */}
      {llmServerLogs.length > 0 && (
        <div>
          <button
            onClick={() => setLogsExpanded(!logsExpanded)}
            className="flex items-center gap-2 text-sm mb-2 hover:opacity-80 transition-opacity"
            style={{ color: 'var(--color-text-secondary)' }}
          >
            {logsExpanded ? (
              <ChevronUp className="w-4 h-4" />
            ) : (
              <ChevronDown className="w-4 h-4" />
            )}
            <span>Startup Logs ({llmServerLogs.length})</span>
          </button>

          {logsExpanded && (
            <div
              className="font-mono text-xs rounded-xl p-4 max-h-48 overflow-y-auto"
              style={{
                background: 'rgba(0, 0, 0, 0.3)',
                color: 'var(--color-text-secondary)',
              }}
            >
              {llmServerLogs.map((log, index) => (
                <div key={index} className="whitespace-pre-wrap break-all">
                  {log.line}
                </div>
              ))}
              <div ref={logsEndRef} />
            </div>
          )}
        </div>
      )}
    </div>
  );
});

ServerStarter.displayName = 'ServerStarter';
