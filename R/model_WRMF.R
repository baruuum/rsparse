#' @title Weighted Regularized Matrix Factorization for collaborative filtering
#' @description Creates a matrix factorization model which is solved through Alternating Least Squares (Weighted ALS for implicit feedback).
#' For implicit feedback see "Collaborative Filtering for Implicit Feedback Datasets" (Hu, Koren, Volinsky).
#' For explicit feedback it corresponds to the classic model for rating matrix decomposition with MSE error (without biases at the moment).
#' These two algorithms are proven to work well in recommender systems.
#' @references
#' \itemize{
#'   \item{Hu, Yifan, Yehuda Koren, and Chris Volinsky.
#'         "Collaborative filtering for implicit feedback datasets."
#'         2008 Eighth IEEE International Conference on Data Mining. Ieee, 2008.}
#'   \item{\url{https://math.stackexchange.com/questions/1072451/analytic-solution-for-matrix-factorization-using-alternating-least-squares/1073170#1073170}}
#'   \item{\url{http://activisiongamescience.github.io/2016/01/11/Implicit-Recommender-Systems-Biased-Matrix-Factorization/}}
#'   \item{\url{http://datamusing.info/blog/2015/01/07/implicit-feedback-and-collaborative-filtering/}}
#'   \item{\url{https://jessesw.com/Rec-System/}}
#'   \item{\url{http://danielnee.com/2016/09/collaborative-filtering-using-alternating-least-squares/}}
#'   \item{\url{http://www.benfrederickson.com/matrix-factorization/}}
#'   \item{\url{http://www.benfrederickson.com/fast-implicit-matrix-factorization/}}
#' }
#' @export
#' @examples
#' data('movielens100k')
#' train = movielens100k[1:900, ]
#' cv = movielens100k[901:nrow(movielens100k), ]
#' model = WRMF$new(rank = 5,  lambda = 0, feedback = 'implicit')
#' user_emb = model$fit_transform(train, n_iter = 5, convergence_tol = -1)
#' item_emb = model$components
#' preds = model$predict(cv, k = 10, not_recommend = cv)
WRMF = R6::R6Class(
  inherit = MatrixFactorizationRecommender,
  classname = "WRMF",

  public = list(
    #' @description creates WRMF model
    #' @param rank size of the latent dimension
    #' @param lambda regularization parameter
    #' @param init initialization of item embeddings
    #' @param preprocess \code{identity()} by default. User spectified function which will
    #' be applied to user-item interaction matrix before running matrix factorization
    #' (also applied during inference time before making predictions).
    #' For example we may want to normalize each row of user-item matrix to have 1 norm.
    #' Or apply \code{log1p()} to discount large counts.
    #' This corresponds to the "confidence" function from
    #' "Collaborative Filtering for Implicit Feedback Datasets" paper.
    #' Note that it will not automatically add +1 to the weights of the positive entries.
    #' @param feedback \code{character} - feedback type - one of \code{c("implicit", "explicit")}
    #' @param non_negative logical, whether to perform non-negative factorization
    #' @param solver \code{character} - solver for "implicit feedback" problem.
    #' One of \code{c("conjugate_gradient", "cholesky")}.
    #' Usually approximate \code{"conjugate_gradient"} is significantly faster and solution is
    #' on par with \code{"cholesky"}
    #' @param cg_steps \code{integer > 0} - max number of internal steps in conjugate gradient
    #' (if "conjugate_gradient" solver used). \code{cg_steps = 3} by default.
    #' Controls precision of linear equation solution at the each ALS step. Usually no need to tune this parameter
    #' @param precision one of \code{c("double", "float")}. Should embeeding matrices be
    #' numeric or float (from \code{float} package). The latter is usually 2x faster and
    #' consumes less RAM. BUT \code{float} matrices are not "base" objects. Use carefully.
    #' @param ... not used at the moment
    initialize = function(rank = 10L,
                          lambda = 0,
                          init = NULL,
                          preprocess = identity,
                          feedback = c("implicit", "explicit"),
                          non_negative = FALSE,
                          solver = c("conjugate_gradient", "cholesky"),
                          cg_steps = 3L,
                          precision = c("double", "float"),
                          ...) {
      stopifnot(is.null(init) || is.matrix(init))
      self$components = init
      solver = match.arg(solver)
      private$precision = match.arg(precision)

      private$als_implicit_fun = if (private$precision == "float") als_implicit_float else als_implicit_double

      private$feedback = match.arg(feedback)

      if (private$feedback == "explicit" && private$precision == "float")
        stop("Explicit solver doesn't support single precision at the moment (but in principle can support).")

      if (solver == "conjugate_gradient" && private$feedback == "explicit")
        logger$warn("only 'cholesky' is available for 'explicit' feedback")

      if (solver == "cholesky") private$solver_code = 0L
      if (solver == "conjugate_gradient") private$solver_code = 1L

      stopifnot(is.integer(cg_steps) && length(cg_steps) == 1)
      private$cg_steps = cg_steps

      private$lambda = as.numeric(lambda)
      private$rank = as.integer(rank)
      stopifnot(is.function(preprocess))
      private$preprocess = preprocess

      private$scorers = new.env(hash = TRUE, parent = emptyenv())
      private$non_negative = non_negative
    },
    #' @description fits the model
    #' @param x input matrix (preferably matrix  in CSC format -`CsparseMatrix`
    #' @param n_iter max number of ALS iterations
    #' @param convergence_tol convergence tolerance checked between iterations
    #' @param ... not used at the moment
    fit_transform = function(x, n_iter = 10L, convergence_tol = 0.005, ...) {
      if (private$feedback == "implicit" ) {
        logger$trace("WRMF$fit_transform(): calling `RhpcBLASctl::blas_set_num_threads(1)` (to avoid thread contention)")
        RhpcBLASctl::blas_set_num_threads(1)
        on.exit({
          n_physical_cores = RhpcBLASctl::get_num_cores()
          logger$trace("WRMF$fit_transform(): on exit `RhpcBLASctl::blas_set_num_threads(%d)` (=number of physical cores)", n_physical_cores)
          RhpcBLASctl::blas_set_num_threads(n_physical_cores)
        })
      }

      logger$trace("convert input to %s if needed", private$internal_matrix_formats$sparse)
      c_ui = as(x, "CsparseMatrix")
      c_ui = private$preprocess(c_ui)
      # strore item_ids in order to use them in predict method
      private$item_ids = colnames(c_ui)

      if ((private$feedback != "explicit") || private$non_negative) {
        logger$trace("check items in input are not negative")
        stopifnot(all(c_ui@x >= 0))
      }

      logger$trace("making another matrix for convenient traverse by users - transposing input matrix")
      c_iu = t(c_ui)

      # init
      n_user = nrow(c_ui)
      n_item = ncol(c_ui)

      logger$trace("initializing U")
      if (private$precision == "double")
        private$U = matrix(0.0, ncol = n_user, nrow = private$rank)
      else
        private$U = flrunif(private$rank, n_user, 0, 0)

      if (is.null(self$components)) {
        if (private$precision == "double")
          self$components = matrix(
            rnorm(n_item * private$rank, 0, 0.01),
            ncol = n_item,
            nrow = private$rank
          )
        else
          self$components = flrnorm(private$rank, n_item)
      } else {
        stopifnot(is.matrix(self$components) || is.float(self$components))
        stopifnot(ncol(self$components) == n_item)
        stopifnot(nrow(self$components) == private$rank)
      }


      private$XtX = tcrossprod(self$components) +
        # make float diagonal matrix - if first component is double - result will be automatically casted to double
        fl(diag(x = private$lambda, nrow = private$rank, ncol = private$rank))

      logger$info("starting factorization with %d threads", getOption("rsparse_omp_threads", 1L))
      trace_lst = vector("list", n_iter)
      loss_prev_iter = Inf
      # iterate
      for (i in seq_len(n_iter)) {

        logger$trace("iter %d by item", i)
        stopifnot(ncol(private$U) == ncol(c_iu))
        if (private$feedback == "implicit") {
          # private$U will be modified in place
          loss = private$als_implicit_fun(c_iu, self$components, private$U, private$XtX,
                                          n_threads = getOption("rsparse_omp_threads", 1L),
                                          lambda = private$lambda,
                                          solver = private$solver_code,
                                          cg_steps = private$cg_steps,
                                          non_negative = private$non_negative)
        } else if (private$feedback == "explicit") {
          private$U = private$solver_explicit_feedback(c_iu, self$components)
        }

        logger$trace("iter %d by user", i)
        stopifnot(ncol(self$components) == ncol(c_ui))

        YtY = tcrossprod(private$U) +
          # make float diagonal matrix - if first component is double - result will be automatically casted to double
          fl(diag(x = private$lambda, nrow = private$rank, ncol = private$rank))

        if (private$feedback == "implicit") {
          # self$components will be modified in place
          loss = private$als_implicit_fun(c_ui, private$U,
                                          self$components,
                                          YtY,
                                          n_threads = getOption("rsparse_omp_threads", 1L),
                                          lambda = private$lambda,
                                          private$solver_code,
                                          private$cg_steps,
                                          private$non_negative)
        } else if (private$feedback == "explicit") {
          self$components = private$solver_explicit_feedback(c_ui, private$U)
        }

        #------------------------------------------------------------------------
        # calculate some metrics if needed in order to diagnose convergence
        #------------------------------------------------------------------------
        if (private$feedback == "explicit")
          loss = als_loss_explicit(c_ui, private$U, self$components, private$lambda, getOption("rsparse_omp_threads", 1L));

        #update XtX
        private$XtX = tcrossprod(self$components) +
          # make float diagonal matrix - if first component is double - result will be automatically casted to double
          fl(diag(x = private$lambda, nrow = private$rank, ncol = private$rank))

        j = 1L
        trace_scors_string = ""
        trace_iter = NULL
        # check if we have scorers
        if (length(private$scorers) > 0) {
          trace_iter = vector("list", length(names(private$scorers)))
          max_k = max(vapply(private$scorers, function(x) as.integer(x[["k"]]), -1L))
          preds = do.call(function(...) self$predict(x = private$cv_data$train, k = max_k, ...),  private$scorers_ellipsis)
          for (sc in names(private$scorers)) {
            scorer = private$scorers[[sc]]
            # preds = do.call(function(...) self$predict(x = private$cv_data$train, k = scorer[["k"]], ...),  private$scorers_ellipsis)
            score = scorer$scorer_function(preds, ...)
            trace_scors_string = sprintf("%s score %s = %f", trace_scors_string, sc, score)
            trace_iter[[j]] = list(iter = i, scorer = sc, value = score)
            j = j + 1L
          }
          trace_iter = data.table::rbindlist(trace_iter)
        }

        trace_lst[[i]] = data.table::rbindlist(list(trace_iter, list(iter = i, scorer = "loss", value = loss)))
        logger$info("iter %d loss = %.4f %s", i, loss, trace_scors_string)
        if (loss_prev_iter / loss - 1 < convergence_tol) {
          logger$info("Converged after %d iterations", i)
          break
        }
        loss_prev_iter = loss
        #------------------------------------------------------------------------
      }

      if (private$precision == "double")
        data.table::setattr(self$components, "dimnames", list(NULL, colnames(x)))
      else
        data.table::setattr(self$components@Data, "dimnames", list(NULL, colnames(x)))

      res = t(private$U)
      private$U = NULL
      setattr(res, "trace", rbindlist(trace_lst))
      if (private$precision == "double")
        setattr(res, "dimnames", list(rownames(x), NULL))
      else
        setattr(res@Data, "dimnames", list(rownames(x), NULL))
      res
    },
    # project new users into latent user space - just make ALS step given fixed items matrix
    #' @description create user embeddings for new input
    #' @param x user-item iteraction matrix
    #' @param ... not used at the moment
    transform = function(x, ...) {
      stopifnot(ncol(x) == ncol(self$components))
      if (private$feedback == "implicit" ) {
        logger$trace("WRMF$transform(): calling `RhpcBLASctl::blas_set_num_threads(1)` (to avoid thread contention)")
        RhpcBLASctl::blas_set_num_threads(1)
        on.exit({
          n_physical_cores = RhpcBLASctl::get_num_cores()
          logger$trace("WRMF$transform(): on exit `RhpcBLASctl::blas_set_num_threads(%d)` (=number of physical cores)", n_physical_cores)
          RhpcBLASctl::blas_set_num_threads(n_physical_cores)
        })
      }
      x = as(x, "CsparseMatrix")
      x = private$preprocess(x)

      if (private$feedback == "implicit") {
        if (private$precision == "double") {
          res = matrix(0, nrow = private$rank, ncol = nrow(x))
        } else {
          res = float(0, nrow = private$rank, ncol = nrow(x))
        }
        private$als_implicit_fun(t(x),
                                 self$components,
                                 res,
                                 private$XtX,
                                 n_threads = getOption("rsparse_omp_threads", 1L),
                                 lambda = private$lambda,
                                 private$solver_code,
                                 private$cg_steps,
                                 private$non_negative)
      } else if (private$feedback == "explicit")
        res = private$solver_explicit_feedback(t(x), self$components)
      else
        stop(sprintf("don't know how to work with feedback = '%s'", private$feedback))
      res = t(res)

      if (private$precision == "double")
        setattr(res, "dimnames", list(rownames(x), NULL))
      else
        setattr(res@Data, "dimnames", list(rownames(x), NULL))
      res
    }
  ),
  private = list(
    # FIXME - not used anymore - consider to remove
    add_scorers = function(x_train, x_cv, specs = list("map10" = "map@10"), ...) {
      stopifnot(data.table::uniqueN(names(specs)) == length(specs))
      private$cv_data = list(train = x_train, cv = x_cv)
      private$scorers_ellipsis = list(...)
      for (scorer_name in names(specs)) {
        # check scorer exists
        if (exists(scorer_name, where = private$scorers, inherits = FALSE))
          stop(sprintf("scorer with name '%s' already exists", scorer_name))

        metric = specs[[scorer_name]]
        scorer_placeholder = list("scorer_function" = NULL, "k" = NULL)

        if (length(grep(pattern = "(ndcg|map)\\@[[:digit:]]+", x = metric)) != 1 )
          stop(sprintf("don't know how add '%s' metric. Only 'loss', 'map@k', 'ndcg@k' are supported", metric))

        scorer_conf = strsplit(metric, "@", T)[[1]]
        scorer_placeholder[["k"]] = as.integer(tail(scorer_conf, 1))

        scorer_fun = scorer_conf[[1]]
        if (scorer_fun == "map")
          scorer_placeholder[["scorer_function"]] =
          function(predictions, ...) mean(ap_k(predictions, private$cv_data$cv, ...), na.rm = T)
        if (scorer_fun == "ndcg")
          scorer_placeholder[["scorer_function"]] =
          function(predictions, ...) mean(ndcg_k(predictions, private$cv_data$cv, ...), na.rm = T)

        private$scorers[[scorer_name]] = scorer_placeholder
      }
    },
    remove_scorer = function(scorer_name) {
      if (!exists(scorer_name, where = private$scorers))
        stop(sprintf("can't find scorer '%s'", scorer_name))
      rm(list = scorer_name, envir = private$scorers)
    },
    solver_code = NULL,
    cg_steps = NULL,
    scorers = NULL,
    lambda = NULL,
    rank = NULL,
    non_negative = NULL,
    # user factor matrix = rank * n_users
    U = NULL,
    # item factor matrix = rank * n_items
    I = NULL,
    # preprocess - transformation of input matrix before passing it to ALS
    # for example we can scale each row or apply log() to values
    # this is essentially "confidence" transformation from WRMF article
    preprocess = NULL,
    feedback = NULL,
    cv_data = NULL,
    scorers_ellipsis = NULL,
    precision = NULL,
    XtX = NULL,
    als_implicit_fun = NULL,
    #------------------------------------------------------------
    solver_explicit_feedback = function(R, X) {
      res = vector("list", ncol(R))
      ridge = diag(x = private$lambda, nrow = private$rank, ncol = private$rank)

      for (i in seq_len(ncol(R))) {
        # find non-zero ratings
        p1 = R@p[[i]]
        p2 = R@p[[i + 1L]]
        j = p1 + seq_len(p2 - p1)
        R_nnz = R@x[j]
        # and corresponding indices
        ind_nnz = R@i[j] + 1L

        X_nnz = X[, ind_nnz, drop = F]
        XtX = tcrossprod(X_nnz) + ridge
        if (private$non_negative) {
          res[[i]] = c_nnls_double(XtX, X_nnz %*% R_nnz, 10000L, 1e-3)
        } else {
          res[[i]] = solve(XtX, X_nnz %*% R_nnz)
        }

      }
      do.call(cbind, res)
    }
  )
)
