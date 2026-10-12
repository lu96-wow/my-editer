#lang racket

;;; edit4/runtime.rkt —— 事件循环 + 后端协议（唯一可变处）
;;;
;;; 每帧：commit-panels!（集中写回）→ 算 frame（缓存）→ 渲染 → draw
;;;        → 读事件 →（resize 则 settle）→ dispatch → 解释 effect（可能产出新 World）。
;;; 只有本模块持有可变状态：几何缓存、上一帧屏幕、后端资源。
;;;
;;; 输入只有两个：Environment（装配期只读）与 World（可变值）。
;;; 命令 / 作用域 / 键表 / 面板 / 装饰都从 Environment 取，不进 World。

(provide (struct-out backend) run)

(require racket/path
         "env.rkt"
         "core/world.rkt" "core/event.rkt" "core/effect.rkt"
         "core/command.rkt" "core/dispatch.rkt"
         "content/model.rkt" "content/adapter.rkt" "content/fs.rkt" "content/tree.rkt"
         "view/render.rkt" "view/panel.rkt" "view/decor.rkt"
         "layout.rkt")

(struct backend (size read-event draw! close) #:transparent)

;; 解释 effect：可能产生新 World（open/reload 要读文件/目录）。
;; 日志进 content.log（日志面板可见）并同时打到 stderr。
(define (log-into w msg)
  (eprintf "~a\n" msg)
  (define c (world-content w))
  (if c (world-set-content w (content-log-append c msg)) w))

;; 成功 → #f；失败 → 错误消息。
(define (io-try thunk)
  (with-handlers ([exn:fail? (lambda (ex) (exn-message ex))]) (thunk) #f))

(define (perform-effect! b w e)
  (cond
    [(quit-effect? e) ((backend-close b)) w]
    [(log-effect? e) (log-into w (log-effect-msg e))]
    [(save-file? e) (define err (io-try (lambda () (fs-write-file (save-file-path e) (save-file-text e)))))
                    (if err (log-into w err) w)]
    [(make-file? e) (define err (io-try (lambda () (fs-make-file (make-file-path e)))))
                    (if err (log-into w err) w)]
    [(make-dir? e) (define err (io-try (lambda () (fs-make-dir (make-dir-path e)))))
                   (if err (log-into w err) w)]
    [(delete-path? e) (define err (io-try (lambda () (fs-delete (delete-path-path e)))))
                      (if err (log-into w err) w)]
    [(reload-tree? e) (refresh-tree! w)]
    [(open-file? e)
     (define path (open-file-path e))
     (define c (world-content w))
     (cond
       [(not c) w]
       [(not (fs-file? path)) (log-into w (format "打不开: ~a" path))]
       [else
        ;; 在编辑器窗口显示（不是面板窗）；同路径已打开则复用。
        (define id (or (content-editor-window c (world-layout w)) (world-focus w)))
        (cond
          [(not id) w]
          [else
           (define did (content-doc-by-path c path))
           (cond
             [did (world-set-content w (content-show c id did))]
             [else
              (define text (fs-read-file path))
              (define-values (c* _did vid)
                (content-add-doc! c text 60 22 path (path->complete-path path)))
              (world-set-content w (content-bind c* id vid))])])])]
    [else w]))

(define (run b env world)
  (define cache (box empty-layout-cache))
  (define fcache (box (hash)))
  (let loop ([w world] [old #f] [old-size #f])
    (define size ((backend-size b)))
    (define c (world-content w))
    (define ed (and c (content-ed c)))
    ;; 面板：纯投影 → 集中写回
    (when ed (commit-panels! ed (project-panels (environment-panels env) w)))
    ;; face：纯投影（按 handle+cursor 缓存）→ 集中写回
    (when ed
      (define-values (fc fprojs) (ensure-faces (unbox fcache) (environment-decor env) w))
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
       (define-values (w* effs)
         (dispatch (environment-commands env) (environment-scopes env)
                   (environment-keymap env) (ctx ev size fr) w))
       (define w** (for/fold ([ww w*]) ([e (in-list effs)]) (perform-effect! b ww e)))
       (if (for/or ([e (in-list effs)]) (quit-effect? e))
           w**
           (loop w** screen size))])))
