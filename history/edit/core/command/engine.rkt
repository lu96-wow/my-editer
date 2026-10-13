#lang racket

;;; edit-rebuild/core/command/engine.rkt —— 迁移桥：用新引擎驱动旧会话
;;;
;;; 迁移第一阶段：**键路由**完全交给新引擎（scope / priority / prefix / effect），
;;; 命令处理暂时仍走旧的 handler 链 + step-base（作为宿主原语）。这样能逐层替换，
;;; 每一步都可测、可回退。
;;;
;;; 做的事：
;;;   1. 旧 keymap（binding -> spec）编译成新 route（含前缀递归）；
;;;   2. 旧 binding / spec / input 与新型别互转；
;;;   3. host 把 run-command 落回旧 step、run-focus 落回 session-set-focus。
;;;
;;; 优先级（大者先）复刻旧 context 栈：
;;;   float 面键 1000-i → 焦点面键 500 → 焦点文档键表 400 → session.keys 100-i

(require (prefix-in n: "../key.rkt")
         (prefix-in n: "../scope.rkt")
         (prefix-in n: "../route.rkt")
         (prefix-in n: "../effect.rkt")
         (prefix-in n: "../dispatch.rkt")
         (prefix-in d: "input.rkt")          ; 旧 input 结构 / 访问器
         "key.rkt"                              ; 旧 binding / spec 构造
         "command.rkt"                          ; 旧 cmd 值 + step
         "../keymap.rkt"                        ; 旧 keymap / prefix
         "../focus.rkt"                         ; focus-set
         "../session/session.rkt"
         "../session/focus.rkt"           ; session-set-focus
         "../session/hook.rkt"            ; session-context
         "../session/adapter.rkt"               ; session-focused-did
         "../surface/surface.rkt")

(provide engine-dispatch engine-execute)

;;; ---------- 型别互转 ----------

(define (old-binding->new b)
  (cond
    [(eq? b 'text) (n:chan-binding 'text)]
    [(eq? b 'paste) (n:chan-binding 'paste)]
    [(eq? b 'resize) (n:chan-binding 'resize)]
    [(and (pair? b) (eq? (car b) 'key)) (n:key-binding (cadr b) (caddr b))]
    [(and (pair? b) (eq? (car b) 'mouse)) (n:mouse-binding (cadr b) (caddr b) (cadddr b))]
    [else b]))

;; 旧 spec → 新动作；前缀登记 id -> 旧 prefix（供 run-prefix 还原）。
(define (old-spec->action spec reg pfx)
  (cond
    [(prefix? spec)
     (define id (prefix-label spec))
     (hash-set! reg id spec)
     (n:begin-prefix id)]
    [(eq? spec text-spec) n:text-spec]
    [(eq? spec resize-spec) n:resize-spec]
    [(eq? spec mouse-press-spec) n:mouse-press-spec]
    [(eq? spec mouse-scroll-up-spec) n:mouse-scroll-up-spec]
    [(eq? spec mouse-scroll-down-spec) n:mouse-scroll-down-spec]
    [else spec]))

;; 旧 keymap → (listof route)；前缀递归展开成 #:prefix 子路由。
(define (compile-km km scope prio pfx reg)
  (append*
   (for/list ([(b spec) (in-hash (keymap-bindings km))])
     (define r (n:route* (old-binding->new b) (old-spec->action spec reg pfx)
                         #:when scope #:priority prio #:prefix pfx))
     (if (prefix? spec)
         (cons r (compile-km (prefix-keymap spec) scope prio (prefix-label spec) reg))
         (list r)))))

;;; ---------- 路由集合（复刻旧 context 栈） ----------

(define (session-routes s)
  (define reg (make-hash))
  (define always (n:scope-always))
  (define floats (for/list ([sf (in-list (session-surfaces s))]
                            #:when (and (surface-float? sf) (surface-keys sf)))
                   sf))
  (define float-routes
    (append* (for/list ([sf (in-list floats)] [i (in-naturals)])
               (compile-km (surface-keys sf) always (- 1000 i) #f reg))))
  (define vid (session-focus-vid s))
  (define focus-sf (and vid (session-surface-for-vid s vid)))
  (define surf-routes
    (if (and focus-sf (surface-keys focus-sf))
        (compile-km (surface-keys focus-sf) always 500 #f reg)
        '()))
  (define did (and vid (session-focused-did s)))
  (define doc-km (and did (hash-ref (session-doc-keymaps s) did #f)))
  (define doc-routes (if doc-km (compile-km doc-km always 400 #f reg) '()))
  (define key-routes
    (append* (for/list ([km (in-list (session-keys s))] [i (in-naturals)])
               (compile-km km always (- 100 i) #f reg))))
  ;; 插件用新 route 注册的路由：键可能是旧 binding（api 暴露的是旧 key 构造子），
  ;; 这里统一归一化成新 binding。
  (define extra-routes
    (for/list ([r (in-list (session-routes-extra s))])
      (struct-copy n:route r [key (old-binding->new (n:route-key r))])))
  (values (append extra-routes float-routes surf-routes doc-routes key-routes)
          reg))

;;; ---------- 宿主 ----------

(define (make-host reg)
  (n:host
   session-context
   ;; run-command：宿主原语（基础命令）。插件的命令由 command 路由处理。
   (lambda (s _target cmd) (values (step-base s cmd) 'handled))
   ;; run-focus
   (lambda (s target) (values (session-set-focus s (focus-set (session-focus s) target)) 'handled))
   ;; run-mode：写进会话的纯值 modes
   (lambda (s name val) (values (session-set-mode s name val) 'handled))
   ;; run-prefix：id -> 旧 prefix 结构
   (lambda (s id) (values (session-set-prefix s (and id (hash-ref reg id))) 'handled))
   ;; spec -> 命令（用输入载荷）
   (lambda (in spec)
     (case spec
       [(text) (cmd-insert (or (n:input-text in) ""))]
       [(resize) (cmd-resize (n:input-cols in) (n:input-rows in))]
       [(mouse-press) (cmd-mouse-press (n:input-col in) (n:input-row in))]
       [(mouse-scroll-up) (cmd-mouse-scroll (n:input-col in) (n:input-row in) -1)]
       [(mouse-scroll-down) (cmd-mouse-scroll (n:input-col in) (n:input-row in) 1)]
       [else spec]))))

;;; ---------- 入口 ----------

(define (old-input->new in)
  (n:input (old-binding->new (d:input-binding in))
           (d:input-text in) (d:input-cols in) (d:input-rows in)
           (d:input-col in) (d:input-row in)))

;; 旧 input（后端 event->input 的产物）→ 新引擎 → 会话。
(define (engine-dispatch s in)
  (define-values (rss reg) (session-routes s))
  (n:dispatch (make-host reg) rss s (old-input->new in)))

;; 命令入口（返回会话）：插件内部的 (step s cmd) 经晚绑定走这里。
(define (engine-execute s cmd)
  (define-values (rss reg) (session-routes s))
  (call-with-values (lambda () (n:execute (make-host reg) rss s 'focus cmd))
    (lambda (s* _h) s*)))

;; 加载本模块即把 command-runner 指向引擎（避免 command.rkt ↔ engine 循环依赖）。
(command-runner engine-execute)
