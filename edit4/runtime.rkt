#lang racket

;;; edit4/runtime.rkt —— 事件循环 + 后端协议 + worker 池（唯一可变处）
;;;
;;; 每帧：emit before-render（钩子）→ commit-panels!（集中写回）→ 算 frame（缓存）
;;;        → 渲染 → draw → 派发 jobs → 读事件（键盘 / 鼠标 / job 结果）→ dispatch
;;;        → 跑钩子 → 解释 effect（可能产出新 World）。
;;; 只有本模块持有可变状态：几何/face 缓存、上一帧屏幕、后端资源、线程。
;;;
;;; 输入只有两个：Environment（装配期只读）与 World（可变值）。
;;; 命令 / 作用域 / 键表 / 面板 / 装饰 / 钩子 / 服务都从 Environment 取，不进 World。

(provide (struct-out backend) run)

(require racket/list racket/path
         "env.rkt" "plugin.rkt"
         "core/world.rkt" "core/event.rkt" "core/effect.rkt"
         "core/command.rkt" "core/dispatch.rkt"
         "core/hook.rkt" "core/job.rkt" "core/mode.rkt"
         "content/model.rkt" "content/adapter.rkt" "content/fs.rkt" "content/tree.rkt"
         "view/render.rkt" "view/panel.rkt" "view/decor.rkt"
         "layout.rkt")

(struct backend (size read-event draw! close) #:transparent)

;; 发一条钩子信号并立即排空（runtime 是唯一能拿到 Environment 的地方）。
(define (emit env w point args)
  (run-hooks (environment-hooks env) (emit! w point args)))

;; 写日志：进 content.log（日志面板可见）并打到 stderr；发 log-appended。
(define (log-into w msg)
  (eprintf "~a\n" msg)
  (define c (world-content w))
  (if c (emit! (world-set-content w (content-log-append c msg)) 'log-appended (list msg)) w))

;; 成功 → #f；失败 → 错误消息。
(define (io-try thunk)
  (with-handlers ([exn:fail? (lambda (ex) (exn-message ex))]) (thunk) #f))

;; 打开一个文件路径到编辑器窗；复用已打开文档 / on-open / doc-key-matcher / document-opened。
(define (open-path env w path)
  (define c (world-content w))
  (cond
    [(not c) w]
    [(not (fs-file? path)) (log-into w (format "打不开: ~a" path))]
    [else
     (define id (or (content-editor-window c (world-layout w)) (world-focus w)))
     (cond
       [(not id) w]
       [else
        (define path* (path->complete-path path))
        (define did (content-doc-by-path c path*))
        (cond
          [did
           ;; 复用：显示到编辑器窗。
           (define w1 (world-set-content w (content-show c id did)))
           (define w2 (run-opens env w1 did path*))
           (emit env w2 'document-opened (list did path*))]
          [else
           (define text (fs-read-file path*))
           (define-values (c* did* vid)
             (content-add-doc! c text 60 22 path (path->complete-path path*)))
           (define w1 (world-set-content w (content-bind c* id vid)))
           ;; mode：按 matcher 给该文档挂键表。
           (define km (match-doc-keys path* (environment-doc-key-matchers env)))
           (define w2 (if km (world-set-content w1 (content-set-doc-key (world-content w1) did* km)) w1))
           (define w3 (run-opens env w2 did* path*))
           (emit env w3 'document-opened (list did* path*))])])]))

;; 解释 effect：可能产生新 World（open/reload 要读文件/目录）。
(define (perform-effect! b env w e)
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
    [(open-file? e) (open-path env w (open-file-path e))]
    [else w]))

;;; ---------- jobs / worker 池 ----------

(define (start-input! b ev-ch)
  (thread (lambda () (let loop () (channel-put ev-ch ((backend-read-event b))) (loop)))))

(define (start-workers! req-ch ev-ch services n)
  (for/list ([_ (in-range (max 1 n))])
    (thread
     (lambda ()
       (let loop ()
         (define j (channel-get req-ch))
         (define res
           (with-handlers ([exn:fail? (lambda (e) (list 'error (exn-message e)))])
             (run-service services j)))
         (channel-put ev-ch (job-event (job-id j) (job-kind j) res (job-tag j)))
         (loop))))))

;; 把 World 里尚未派发的 job 送去 worker。
(define (dispatch-new-jobs! sent w req-ch)
  (for ([j (in-list (jobs w))] #:unless (hash-has-key? (unbox sent) (job-id j)))
    (set-box! sent (hash-set (unbox sent) (job-id j) #t))
    (channel-put req-ch j)))

;;; ---------- 主循环 ----------

(define (run b env world)
  (define cache (box empty-layout-cache))
  (define ev-ch (make-channel))
  (define req-ch (make-channel))
  (define services (environment-services env))
  (define input-thread (start-input! b ev-ch))
  (define worker-threads (start-workers! req-ch ev-ch services 2))
  (define sent (box (hash)))
  (define (stop!) (for-each kill-thread (cons input-thread worker-threads)))
  (let loop ([w (run-boots env world)] [old #f] [old-size #f])
    (define size ((backend-size b)))
    ;; before-render 钩子（如浮窗重定位）
    (define w0 (emit env w 'before-render (list size)))
    (define c (world-content w0))
    (define ed (and c (content-ed c)))
    ;; 面板：纯投影 → 集中写回
    (when ed (commit-panels! ed (project-panels (environment-panels env) w0)))
    ;; face：槽驱动增量（编辑时引擎 fork 推进，这里推进光标 + 写回脏行）
    (when ed (apply-faces! ed (environment-decor env) w0))
    (define-values (cache* fr) (ensure-layout (unbox cache) (world-layout w0) (world-floats w0) size))
    (set-box! cache cache*)
    (define id->vid (and c (lambda (id) (content-vid-of c id))))
    (define active (and id->vid (id->vid (world-focus w0))))
    (define-values (screen rends sels)
      (if (and ed id->vid)
          (render-frame ed fr id->vid active (car size) (cdr size)
                        (and (equal? size old-size) old))
          (values #f '() '())))
    ((backend-draw! b) (append rends sels))
    (dispatch-new-jobs! sent w0 req-ch)
    (define ev (channel-get ev-ch))
    (cond
      [(resize-event? ev)
       (define area (rect 0 0 (resize-event-w ev) (resize-event-h ev)))
       (loop (world-set-layout w0 (settle (world-layout w0) area)) screen old-size)]
      [(job-event? ev)
       (define w1 (job-finish w0 (job-event-id ev) (job-event-result ev)))
       (set-box! sent (hash-remove (unbox sent) (job-event-id ev)))
       (loop (emit env w1 'job (list (job-event-id ev) (job-event-kind ev)
                                     (job-event-result ev) (job-event-tag ev)))
             screen size)]
      [else
       (define f0 (world-focus w0))
       (define focused-vid (and c (content-vid-of c f0)))
       (define doc-km (if (and c focused-vid)
                          (or (content-doc-key c (content-did-of c focused-vid)) '())
                          '()))
       (define-values (w1 effs)
         (dispatch (environment-commands env) (environment-scopes env)
                   (environment-keymap env) (ctx ev size fr) w0 #:doc-keymap doc-km))
       (define w2 (if (eqv? f0 (world-focus w1))
                      w1
                      (emit env w1 'focus-changed (list (world-focus w1) f0))))
       (define w3 (for/fold ([ww w2]) ([e (in-list effs)]) (perform-effect! b env ww e)))
       (define w4 (run-hooks (environment-hooks env) w3))
       (if (for/or ([e (in-list effs)]) (quit-effect? e))
           (begin (stop!) w4)
           (loop w4 screen size))])))
