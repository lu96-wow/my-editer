#lang racket

;;; 33-plugin-host.rkt —— 宿主：require 插件即自动生效
;;;
;;;   racket temp/33-plugin-host.rkt          # 进 TUI（注意：左侧已自动多出 *hello* 面板）
;;;   racket temp/33-plugin-host.rkt check    # headless 自检
;;;
;;; 宿主**没有**手动插入面板、没有手动注册类型 —— 只 require 了 32-hello-plugin.rkt。

(require tui
         "../core/editor.rkt"
         "../edit-tui/theme/main.rkt"
         "../edit-tui/core-render/main.rkt"
         "../edit-tui/command/main.rkt"
         "../edit-tui/layout/main.rkt"
         "../edit-tui/app/api/main.rkt"
         "32-hello-plugin.rkt")                     ; ← require 即注册

;;; ════════════════ 宿主只搭一个"纯编辑区"布局 ════════════════

(define (base-world)
  (make-world #:area (rect 0 0 60 12)
              #:layout (pane 'editor #:view #f #:borders '() #:role 'editor)
              #:focus (leaf-ref 'editor)))

;;; ════════════════ 入口 ════════════════

(module+ main
  (define args (current-command-line-arguments))
  (if (and (positive? (vector-length args)) (equal? (vector-ref args 0) "check"))
      (run-check!)
      (run-app (base-world))))                      ; run-app 内部自动 plugins-apply

;;; ════════════════ headless 自检 ════════════════

(define (check label ok?)
  (if ok? (printf "  ✓ ~a\n" label) (error 'check "~a 失败" label)))

(define (run-check!)
  ;; 1) require 过插件 → 装配后布局里应有 'hello 面板（在 editor 左侧）
  (define w (plugins-apply (base-world)))
  (check "插件已注册" (plugins-known? 'hello))
  (check "面板已插进当前 layout" (tree-contains? (world-layout w) 'hello))
  (check "面板在 editor 左侧"
         (let-values ([(pls _pa _cuts) (tree-solve (world-layout w) (world-area w))])
           (define hs (for/list ([p pls]) (list (car p) (rect-x (cadr p)))))
           (< (cadr (assq 'hello hs)) (cadr (assq 'editor hs)))))
  (check "面板 role = 'panel" (eq? (leaf-role (tree-find (world-layout w) 'hello)) 'panel))
  (check "on-load 挂上了文档 view"
         (and (leaf-view (tree-find (world-layout w) 'hello)) #t))
  (check "面板文档类型 = 'hello"
         (eq? (view-kind (world-ref->view w (leaf-ref 'hello))) 'hello))

  ;; 2) 幂等：再 apply 一次不会重复插
  (define w2 (plugins-apply w))
  (check "重复装配幂等（不重复插）"
         (= 1 (for/sum ([l (in-list (tree-leaves (world-layout w2)))]
                        #:when (eq? (leaf-id l) 'hello)) 1)))

  ;; 3) 不注册就没有：清空注册表 → 装配后没有面板
  (plugins-reset!)
  (define w3 (plugins-apply (base-world)))
  (check "清空注册 → 没有面板" (not (tree-contains? (world-layout w3) 'hello)))
  (check "清空注册 → 没装类型" (not (plugins-known? 'hello)))

  (displayln "plugin demo: 自检 OK"))
