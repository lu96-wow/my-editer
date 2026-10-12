#lang racket

;;; edit4/runtime.rkt —— 事件循环 + 后端协议（唯一可变处）
;;;
;;; 每帧：commit-panels!（集中写回）→ 算 frame（缓存）→ 渲染 → draw
;;;        → 读事件 →（resize 则 settle）→ dispatch → 解释 effect（可能产出新 World）。
;;; 只有本模块持有可变状态：几何缓存、上一帧屏幕、后端资源。

(provide (struct-out backend) run)

(require racket/path
         "core/world.rkt" "core/event.rkt" "core/effect.rkt"
         "core/command.rkt" "core/dispatch.rkt"
         "content/content.rkt" "content/engine.rkt" "content/fs.rkt"
         "view/render.rkt" "view/panels.rkt" "view/face-plugin.rkt"
         "layout.rkt")

(struct backend (size read-event draw! close) #:transparent)

;; 解释 effect：可能产生新 World（open/reload 要读文件/目录）。
(define (perform-effect! b w e)
  (cond
    [(quit-effect? e) ((backend-close b)) w]
    [(log-effect? e) (eprintf "~a\n" (log-effect-msg e)) w]
    [(save-file? e) (fs-write-file (save-file-path e) (save-file-text e)) w]
    [(reload-tree? e) (refresh-tree! w)]
    [(open-file? e)
     (define path (open-file-path e))
     (define c (world-content w))
     (define id (world-focus w))
     (cond
       [(not (and c id)) w]
       [else
        (define text (fs-read-file path))
        (define-values (c* _did vid) (content-add-doc! c text 60 22 path (path->complete-path path)))
        (world-set-content w (content-bind c* id vid))])]
    [else w]))

(define (run b reg scopes km panels faces world)
  (define cache (box empty-layout-cache))
  (define fcache (box (hash)))
  (let loop ([w world] [old #f] [old-size #f])
    (define size ((backend-size b)))
    (define c (world-content w))
    (define ed (and c (content-ed c)))
    ;; 面板：纯投影 → 集中写回
    (when ed (commit-panels! ed (project-panels panels w)))
    ;; face：纯投影（按 handle+cursor 缓存）→ 集中写回
    (when ed
      (define-values (fc fprojs) (ensure-faces (unbox fcache) faces w))
      (set-box! fcache fc)
      (commit-faces! ed fprojs))
    (define-values (cache* fr) (ensure-layout (unbox cache) (world-layout w) (world-floats w) size))
    (set-box! cache cache*)
    (define id->vid (and c (lambda (id) (content-vid-of c id))))
    (define active (and id->vid (id->vid (world-focus w))))
    (define-values (screen rends sels)
      (if (and ed id->vid)
          (render-frame ed fr id->vid active (car size) (cdr size)
                        (and (equal? size old-size) old))
          (values #f '() '())))
    ((backend-draw! b) (append rends sels))
    (define ev ((backend-read-event b)))
    (cond
      [(resize-event? ev)
       (define area (rect 0 0 (resize-event-w ev) (resize-event-h ev)))
       (loop (world-set-layout w (settle (world-layout w) area)) screen old-size)]
      [else
       (define-values (w* effs) (dispatch reg scopes km (ctx ev size fr) w))
       (define w** (for/fold ([ww w*]) ([e (in-list effs)]) (perform-effect! b ww e)))
       (if (for/or ([e (in-list effs)]) (quit-effect? e))
           w**
           (loop w** screen size))])))
