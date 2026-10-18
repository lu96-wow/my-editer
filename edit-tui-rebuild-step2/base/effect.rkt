#lang racket

;;; base/effect.rkt —— 效果即数据（纯值，不执行）
;;; layer  : base
;;; effect : 无（效果是数据；执行在 effects/interpreter）

;;; 命令返回 Transition（见 transition.rkt），其中 effects 是一串**有序**效果；
;;; Runtime 在边缘按顺序解释。State 里绝不直接持有 core 句柄。
;;;
;;; 分两类：
;;;
;;;   引擎写（Engine 解释；唯一持有 core buffer/view 的地方）
;;;     edit-effect     view op
;;;     insert-text-effect view text    （text 是数据；engine 转成 op-type）
;;;     set-text-effect    view text    （整篇设置）
;;;     set-input-prompt-effect view prompt  （整篇设置 + prompt 前缀只读）
;;;     select-effect   view selections
;;;     scroll-effect   view delta
;;;     nav-effect      view dir        ('left/'right/'up/'down/'home/'end)
;;;     undo-effect     view
;;;     redo-effect     view
;;;     open-doc-effect spec k        k : state doc-id view-id -> transition
;;;     open-view-effect doc k        k : state view-id -> transition
;;;     close-view-effect view
;;;     close-doc-effect doc
;;;     save-doc-effect doc k          k : state ok? -> transition
;;;
;;;   IO / 异步 / 调度（Runtime 解释）
;;;     read-file-effect  path k       k : state text|#f -> transition
;;;     write-file-effect path text k  k : state ok? -> transition
;;;     make-directory-effect path k   k : state ok? -> transition
;;;     delete-file-effect path k      k : state ok? -> transition
;;;     spawn-effect      job thunk   完成后回投 internal-event 'job-done
;;;     timer-effect      delay event 到点回投 event
;;;     emit-effect       event       立即回投（排在当前批次后）
;;;     quit-effect       —           退出事件循环
;;;
;;; 暂定：open-doc / read-file 的 k 是过程。效果是运行时值，不属于 State；
;;; 若以后要“效果日志可序列化”，把 k 换成 command-id + args，由 env 查表。

(provide (struct-out continuation)
         make-continuation
         (struct-out edit-effect)
         (struct-out insert-text-effect)
         (struct-out set-text-effect)
         (struct-out set-input-prompt-effect)
         (struct-out set-face-layer-effect)
         (struct-out replace-range-effect)
         (struct-out ensure-view-effect)
         (struct-out submit-service-effect)
         (struct-out query-effect)
         (struct-out select-effect)
         (struct-out scroll-effect)
         (struct-out nav-effect)
         (struct-out undo-effect)
         (struct-out redo-effect)
         (struct-out open-doc-effect)
         (struct-out open-view-effect)
         (struct-out close-view-effect)
         (struct-out close-doc-effect)
         (struct-out save-doc-effect)
         (struct-out read-file-effect)
         (struct-out write-file-effect)
         (struct-out make-directory-effect)
         (struct-out delete-file-effect)
         (struct-out spawn-effect)
         (struct-out timer-effect)
         (struct-out emit-effect)
         (struct-out quit-effect)
         effect? effect-kind)

;; 数据 continuation：effect 里不再必须夹带闭包。
;; tag -> handler 注册在 environment.continuations；handler : (state data . results -> transition)。
(struct continuation (tag data) #:transparent)

(define (make-continuation tag data)
  (unless (symbol? tag)
    (error 'make-continuation "tag 要是 symbol：~a" tag))
  (continuation tag data))

(struct edit-effect   (view op)        #:transparent)
(struct insert-text-effect (view text) #:transparent)
(struct set-text-effect (view text)    #:transparent)
(struct set-input-prompt-effect (view prompt) #:transparent)
;; 设置一个 document 的**一个 face 层**（语法高亮 / 括号底色……）。
;;   layer : symbol                             层名（层序见 environment.face-layers）
;;   fills : (listof (list l0 c0 l1 c1 face))   坐标是 (line, col)，与 core 的 fill 形状一致
;;
;; 语义：替换该层的内容；各层按 layer 顺序**逐分量合成**（模型在 model/face-layer.rkt），
;; 所以“写前景的插件”和“写背景的插件”不会互相覆盖。
(struct set-face-layer-effect (doc layer fills) #:transparent)
;; 替换一个 view 的 range（补全用）：range 是 core 的 range 值，text 是替换文本。
(struct replace-range-effect (view range text) #:transparent)
;; 把这个 view 的光标夹进窗口（布局刚变化时用：例如打开底部文档面板）。
(struct ensure-view-effect (view) #:transparent)
;; 把一段**纯计算**交给后台 worker（多进程）去做，结果以 job-done 信号回来。
;;   job     : any/c（调用方自定，回来时原样带回，用于对账 / 丢弃过期结果）
;;   kind    : symbol（worker 里的 service 名）
;;   payload : any/c（必须可跨 place 传递：list / vector / string / symbol / number / #:prefab struct）
;;
;; 为什么是 effect 而不是直接调用：worker 是 runtime 的私有资源，插件只描述工作。
(struct submit-service-effect (job kind payload) #:transparent)
;; query-effect 是 submit-service-effect 的语义化别名：一次性只读查询 / 纯计算。
;; runtime 的处理与 submit-service-effect 相同；新代码优先用 query-effect。
(struct query-effect (job kind payload) #:transparent)
(struct select-effect (view selections)#:transparent)
(struct scroll-effect (view delta)     #:transparent)
(struct nav-effect     (view dir)      #:transparent)
(struct undo-effect    (view)          #:transparent)
(struct redo-effect    (view)          #:transparent)
(struct open-doc-effect  (spec k)      #:transparent)
(struct open-view-effect (doc k)       #:transparent)
(struct close-view-effect (view)       #:transparent)
(struct close-doc-effect (doc)         #:transparent)
(struct save-doc-effect  (doc k)       #:transparent)
(struct read-file-effect (path k)      #:transparent)
(struct write-file-effect(path text k) #:transparent)
(struct make-directory-effect (path k) #:transparent)
(struct delete-file-effect (path k)    #:transparent)
(struct spawn-effect     (job thunk)   #:transparent)
(struct timer-effect     (delay event) #:transparent)
(struct emit-effect      (event)       #:transparent)
(struct quit-effect      ()            #:transparent)

(define (effect? x)
  (or (edit-effect? x) (insert-text-effect? x) (set-text-effect? x)
      (set-input-prompt-effect? x)
      (set-face-layer-effect? x) (replace-range-effect? x) (ensure-view-effect? x)
      (submit-service-effect? x) (query-effect? x)
      (select-effect? x) (scroll-effect? x)
      (nav-effect? x) (undo-effect? x) (redo-effect? x)
      (open-doc-effect? x) (open-view-effect? x) (close-view-effect? x)
      (close-doc-effect? x) (save-doc-effect? x)
      (read-file-effect? x) (write-file-effect? x)
      (make-directory-effect? x) (delete-file-effect? x)
      (spawn-effect? x) (timer-effect? x) (emit-effect? x) (quit-effect? x)))

(define (effect-kind x)
  (cond [(edit-effect? x)      'edit]
        [(insert-text-effect? x) 'insert-text]
        [(set-text-effect? x)    'set-text]
        [(set-input-prompt-effect? x) 'set-input-prompt]
        [(set-face-layer-effect? x) 'set-face-layer]
        [(replace-range-effect? x) 'replace-range]
        [(ensure-view-effect? x)   'ensure-view]
        [(submit-service-effect? x) 'submit-service]
        [(query-effect? x) 'query]
        [(select-effect? x)    'select]
        [(scroll-effect? x)    'scroll]
        [(nav-effect? x)       'nav]
        [(undo-effect? x)      'undo]
        [(redo-effect? x)      'redo]
        [(open-doc-effect? x)  'open-doc]
        [(open-view-effect? x) 'open-view]
        [(close-view-effect? x)'close-view]
        [(close-doc-effect? x) 'close-doc]
        [(save-doc-effect? x)  'save-doc]
        [(read-file-effect? x) 'read-file]
        [(write-file-effect? x)'write-file]
        [(make-directory-effect? x) 'make-directory]
        [(delete-file-effect? x)    'delete-file]
        [(spawn-effect? x)     'spawn]
        [(timer-effect? x)     'timer]
        [(emit-effect? x)      'emit]
        [(quit-effect? x)      'quit]
        [else                  'unknown]))
