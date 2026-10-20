#lang racket

;;; edit-tui-rebuild/filetree/commands.rkt —— 文件树命令
;;;
;;; Enter:
;;;   root/dir -> 展开 / 折叠
;;;   file     -> 已打开：聚焦已有 panel / 进入 placement
;;;               未打开：read-file -> resource-open -> placement
;;;
;;; 目标 panel 由用户选：
;;;   鼠标点 editor panel
;;;   或 C-x 方向切换焦点后 Enter
;;; 新文档的 per-doc 键表来自 app-state-editor-tables（通常是编辑操作表）。

(require racket/path
         "../app/state.rkt"
         "../app/action.rkt"
         "../app/placement.rkt"
         "../command/api.rkt"
         "../layout/api.rkt"
         "../panel/api.rkt"
         "../resource/api.rkt"
         "model.rkt"
         "lines.rkt"
         "scan.rkt")

(provide filetree-command-table
         filetree-panel-stack
         filetree-install-state
         filetree-nav-command
         filetree-enter-command
         filetree-refresh-command)

(define (notice state text)
  (struct-copy app-state state [message text]))

(define (ft-state state)
  (hash-ref (app-state-store state) 'filetree (empty-filetree)))

(define (set-ft-state state f)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'filetree f)]))

(define (ft-rows state)
  (filetree-rows (ft-state state)))

(define (ft-cursor state)
  (filetree-cursor (ft-state state)))

(define (current-line state)
  (filetree-line-at (ft-rows state) (ft-cursor state)))

(define (set-cursor state n)
  (set-ft-state state (filetree-set-line (ft-state state) n)))

(define (clamp n len)
  (cond [(zero? len) 0]
        [else (max 0 (min n (sub1 len)))]))

(define (filetree-nav-command kind)
  (λ (state)
    (define len (length (ft-rows state)))
    (define cur (ft-cursor state))
    (define next
      (case kind
        [(up) (max 0 (sub1 cur))]
        [(down) (min (max 0 (sub1 len)) (add1 cur))]
        [(home) 0]
        [(end) (max 0 (sub1 len))]
        [else cur]))
    (values (set-cursor state (clamp next len)) '())))

(define (find-resource-by-path state path)
  (define pn (filetree-normalize-path path))
  (for/first ([r (in-list (resource-list (app-state-resources state)))]
              #:when
              (let ([p (resource-path (app-state-resources state) (resource-id r))])
                (and p (equal? pn (filetree-normalize-path p)))))
    r))

(define (panel-containing-view state vid)
  (for/first ([p (in-list (layout-panel-resources (app-state-layout state)))]
              #:when (memv vid (panel-views p)))
    (panel-id p)))

(define (focus-resource-of state pid)
  (define p (layout-panel (app-state-layout state) pid))
  (define vid (and p (panel-view p)))
  (and vid (resource-of-view (app-state-resources state) vid)))

(define (focus-panel state pid)
  (define layout* (layout-set-focus (app-state-layout state) pid))
  (define s1 (struct-copy app-state state [layout layout*]))
  (struct-copy app-state s1 [focus-resource (focus-resource-of s1 pid)]))

(define (open-existing state r)
  (define store (app-state-resources state))
  (define vid (first (resource-view-ids store (resource-id r))))
  (define pid (and vid (panel-containing-view state vid)))
  (cond
    [(not vid) (values (notice state "filetree: resource has no view") '())]
    [pid
     (define s (focus-panel state pid))
     (values (struct-copy app-state s [message "file opened"]) '())]
    [else
     (values (start-placement state vid) '())]))

(define (open-file state path)
  (define r (find-resource-by-path state path))
  (cond
    [r (open-existing state r)]
    [else
     ;; 新文档带 app 的默认 editor 键表（overlays 里的全局键对任何面板都生效，
     ;; 不用再重复放进 per-doc 表）。
     (values state
             (list (open-file-action (filetree-normalize-path path)
                                     (app-state-editor-tables state))))]))

(define (filetree-enter-command state)
  (define l (current-line state))
  (cond
    [(not l) (values (notice state "filetree: no line") '())]
    [(memq (filetree-line-kind l) '(root dir))
     (define f (ft-state state))
     (values (set-ft-state state
                           (filetree-toggle-expand f (filetree-line-path l)))
             '())]
    [else (open-file state (filetree-line-path l))]))

;;; 行投影按「root + expanded + opened」缓存；外部文件变化不会自动反映。
;;; C-r 丢掉缓存，下一帧重新扫一次目录。
(define (filetree-refresh-command state)
  (values (set-ft-state state (filetree-invalidate (ft-state state))) '()))

(define filetree-command-table
  (keys
   [(key 'up)    (filetree-nav-command 'up)]
   [(key 'down)  (filetree-nav-command 'down)]
   [(key 'home)  (filetree-nav-command 'home)]
   [(key 'end)   (filetree-nav-command 'end)]
   [(key 'enter) filetree-enter-command]
   [(key 'r 'ctrl) filetree-refresh-command]))

(define filetree-panel-stack
  (command-table-stack-push command-table-stack-empty filetree-command-table))

(define (filetree-install-state state view root #:panel-id [panel-id 'filetree])
  (define root* (filetree-normalize-path root))
  (define f (filetree-set-view
             (filetree-toggle-expand (empty-filetree) root*)
             view))
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'filetree f)]
               [root root*]
               [panel-stacks (hash-set (app-state-panel-stacks state)
                                       panel-id
                                       filetree-panel-stack)]))
