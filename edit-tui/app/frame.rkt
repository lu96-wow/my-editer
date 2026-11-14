#lang racket

;;; edit-tui/app/frame.rkt —— status / 插件 sync / overlay / render
;;;
;;; 渲染顺序固定为：
;;;   panel 尺寸 -> status 内容 -> 插件 sync -> overlay -> render patch
;;; 这是纯投影：不解释命令，不处理事件。

(require racket/string
         "../editor/host-api.rkt"
         "../editor/error.rkt"
         (only-in "../core/command/api.rkt" key->string)
         (only-in "../../core/editor.rkt" make-panel)
         "../features/input/api.rkt"
         "../features/placement/api.rkt"
         "../host/render/core.rkt"
         "../host/source.rkt"
         "../host/workspace.rkt"
         "bootstrap.rkt")

(provide sync-status!
         render-frame)

;;; ════════════════ status ════════════════

(define (status-line state engine)
  (define vid (editor-focus-view-id state))
  (define line (add1 (or (and vid (engine-view-point-line engine vid)) 0)))
  (define col (add1 (or (and vid (engine-view-point-column engine vid)) 0)))
  (define panes (length (or (editor-visible-editor-panels state) '())))
  (define r (state-resource-for-view state vid))
  (define name
    (cond
      [(not r) "[no file]"]
      [else
       (define path (resource-path r))
       (if path
           (resource-display-path (state-workspace-root state) path)
           (resource-name r))]))
  (define dirty?
    (and r (resource-dirty? r (engine-doc-version engine (resource-doc-id r)))))
  (define pending (state-pending state))
  (define pending-text
    (and (pair? pending)
         (format " [~a]" (string-join (map key->string pending) " "))))
  (define placement (and (editor-placement-active? state) "placement"))
  (define flash (state-flash state))
  (string-join
   (filter values
           (list name
                 (and dirty? "*")
                 (format "~a:~a" line col)
                 (format "panes:~a" panes)
                 "pair+indent"
                 placement
                 pending-text
                 (and (positive? (string-length flash)) flash)))
   "  "))

(define (sync-status! state engine)
  (define text (status-line state engine))
  (engine-set-view-content! engine status-vid (list text) (list 'status-bar))
  (engine-set-view-cursor! engine status-vid 0 #:column 0)
  state)

(define (sync-errors! state engine)
  (define-values (lines faces) (errors->lines+faces (state-errors state)))
  (engine-set-view-content! engine errors-vid lines faces)
  (engine-set-view-cursor! engine errors-vid 0 #:column 0)
  state)

;;; ════════════════ frame ════════════════

(define (render-frame ed state cache)
  (define area (state-area state))
  (define rows (rect-h area))
  (define cols (rect-w area))
  (define panels (or (editor-layout-panels ed state) '()))
  ;; 顺序：panel 尺寸 -> status 内容 -> 插件 sync -> 渲染。
  ;; status 是 host 投影，先写好，避免派生插件在下一帧才发现它的 version 变了。
  (panels-sync! panels)
  (void (sync-status! state (editor-engine ed)))
  (void (sync-errors! state (editor-engine ed)))
  (void (editor-input-sync! ed state))
  ;; 来源权威必须先于 workspace：completion / docs 在 sync 里读 workspace。
  (source-sync! ed state)
  (workspace-sync! ed state)
  (define state* (run-plugin-syncs ed state))
  (define engine (editor-engine ed))
  (define-values (state** overlays) (run-plugin-overlays ed state*))
  (define overlay-panels
    (for/list ([ov (in-list overlays)])
      (make-panel (engine-view-object engine (editor-overlay-view-id ov))
                  (editor-overlay-rect ov)
                  (editor-overlay-borders ov)
                  #:face (editor-overlay-face ov)
                  #:weight (editor-overlay-weight ov)
                  #:deep (editor-overlay-deep ov))))
  (unless (null? overlay-panels)
    (panels-sync! overlay-panels))
  (define all-panels (append panels overlay-panels))
  (define focus-view (editor-focus-view ed state**))
  (define-values (cache* rows* sels*)
    (render-display-patch all-panels focus-view cols rows cache))
  (define out
    (bytes-append (if cache (bytes) (render-clear))
                  (render-pieces (append rows* sels*))))
  (values state** cache* out))
