#lang racket

;;; edit-tui/edit.rkt —— 可运行入口
;;;
;;; 具体装配在 app/bootstrap.rkt，事件在 app/event.rkt，渲染在 app/frame.rkt，
;;; action 解释在 app/actions.rkt。这里只负责终端生命周期和对外 re-export，
;;; 让测试 / headless 入口继续 require edit-tui/edit.rkt。

(require racket/cmdline
         racket/string
         (prefix-in tui: tui)
         "editor/host-api.rkt"
         "app/bootstrap.rkt"
         "app/event.rkt"
         "app/frame.rkt"
         "host/jobs.rkt"
         "host/timers.rkt"
         "host/face-jobs.rkt"
         "host/persist.rkt"
         "host/render/theme.rkt"
         "config/theme/default.rkt")

;; 主题是配置数据；安装是 host 副作用。
(install-theme! default-theme)

(provide run-editor
         make-editor-app
         run-demo-editor
         render-frame
         sync-status!
         handle-editor-event
         handle-job-result)

;;; ════════════════ 终端入口 ════════════════

(define (run-demo-editor
         #:workspace-root [root (resource-normalize-path (current-directory))])
  (define root* (resource-normalize-path root))
  (define-values (ed state0) (make-editor-app #:workspace-root root*))
  (define state (load-editor-session! ed state0 #:workspace-root root*))
  (tui:with-tui
   (lambda ()
     (tui:cursor-hide)
     (tui:enable-mouse!)
     (tui:enable-bracketed-paste!)
     (define-values (rows cols) (tui:get-window-size))
     (define area
       (if (and rows cols (positive? rows) (positive? cols))
           (rect 0 0 cols rows)
           (rect 0 0 80 24)))
     (define runtime
       (start-job-runtime (editor-services ed)
                          #:workers 2))
     (define timer-runtime
       (start-timer-runtime))
     (define face-runtime
       (start-face-runtime))
     (editor-set-timer-service! ed (timer-runtime-service timer-runtime))
     (dynamic-wind
      void
      (λ ()
        (define final
          (parameterize ([current-face-submit (face-runtime-submit face-runtime)])
            (run-editor ed
                        (state-with-async (state-with-screen state area) #t)
                        #:write-bytes (λ (b) (tui:put-bytes b) (tui:flush!))
                        #:job-runtime runtime
                        #:timer-runtime timer-runtime
                        #:face-runtime face-runtime
                        #:register-source tui:on-source)))
        (when (state-quit? final)
          (cond
            [(state-save-session? final)
             (void (save-editor-session! ed final #:workspace-root root*))]
            [else
             ;; C-q q：明确删除已保存布局，下次启动回到默认布局。
             (void (clear-editor-session! #:workspace-root root*))]))
        final)
      (λ ()
        (stop-face-runtime face-runtime)
        (stop-job-runtime runtime)
        (stop-timer-runtime timer-runtime))))))

;; CLI 参数 -> 绝对、简化后的工作目录字符串。
(define (workspace-root-argument arg)
  (define root (resource-normalize-path arg))
  (unless (directory-exists? (string->path root))
    (error 'edit-tui "工作目录不存在或不是目录：~a" root))
  root)

(module+ main
  (command-line
   #:program "edit-tui"
   #:usage-help "可选参数：工作目录（相对路径会转换为绝对路径）"
   #:args args
   (define root
     (cond
       [(null? args) (resource-normalize-path (current-directory))]
       [(null? (cdr args)) (workspace-root-argument (car args))]
       [else
        (error 'edit-tui "最多只能指定一个工作目录：~a"
               (string-join args " "))]))
   ;; 工作目录同时作为 workspace root 和进程 cwd；路径已在上面转成绝对路径。
   (current-directory root)
   (void (run-demo-editor #:workspace-root root))))
