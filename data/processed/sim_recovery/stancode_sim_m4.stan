// generated with brms 2.23.0
functions {
  /* integer sequence of values
   * Args:
   *   start: starting integer
   *   end: ending integer
   * Returns:
   *   an integer sequence from start to end
   */
  array[] int sequence(int start, int end) {
    array[end - start + 1] int seq;
    for (n in 1:num_elements(seq)) {
      seq[n] = n + start - 1;
    }
    return seq;
  }
 /* compute correlated group-level effects
  * Args:
  *   z: matrix of unscaled group-level effects
  *   SD: vector of standard deviation parameters
  *   L: cholesky factor correlation matrix
  * Returns:
  *   matrix of scaled group-level effects
  */
  matrix scale_r_cor(matrix z, vector SD, matrix L) {
    // r is stored in another dimension order than z
    return transpose(diag_pre_multiply(SD, L) * z);
  }

  // compute partial sums of the log-likelihood
  real partial_log_lik_lpmf(array[] int seq, int start, int end, data vector Y, data matrix Xc, vector b, real Intercept, real sigma, data array[] int J_1_1, data array[] real W_1_1, data array[] int J_1_2, data array[] real W_1_2, data array[] int J_1_3, data array[] real W_1_3, data array[] int J_1_4, data array[] real W_1_4, data array[] int J_1_5, data array[] real W_1_5, data array[] int J_1_6, data array[] real W_1_6, data array[] int J_1_7, data array[] real W_1_7, data array[] int J_1_8, data array[] real W_1_8, data array[] int J_1_9, data array[] real W_1_9, data array[] int J_1_10, data array[] real W_1_10, data array[] int J_1_11, data array[] real W_1_11, data array[] int J_1_12, data array[] real W_1_12, data array[] int J_1_13, data array[] real W_1_13, data array[] int J_1_14, data array[] real W_1_14, data vector Z_1_1_1, data vector Z_1_1_2, data vector Z_1_1_3, data vector Z_1_1_4, data vector Z_1_1_5, data vector Z_1_1_6, data vector Z_1_1_7, data vector Z_1_1_8, data vector Z_1_1_9, data vector Z_1_1_10, data vector Z_1_1_11, data vector Z_1_1_12, data vector Z_1_1_13, data vector Z_1_1_14, data vector Z_1_2_1, data vector Z_1_2_2, data vector Z_1_2_3, data vector Z_1_2_4, data vector Z_1_2_5, data vector Z_1_2_6, data vector Z_1_2_7, data vector Z_1_2_8, data vector Z_1_2_9, data vector Z_1_2_10, data vector Z_1_2_11, data vector Z_1_2_12, data vector Z_1_2_13, data vector Z_1_2_14, vector r_1_1, vector r_1_2, data array[] int J_2, data vector Z_2_1, data vector Z_2_2, vector r_2_1, vector r_2_2) {
    real ptarget = 0;
    int N = end - start + 1;
    // initialize linear predictor term
    vector[N] mu = rep_vector(0.0, N);
    mu += Intercept;
    for (n in 1:N) {
      // add more terms to the linear predictor
      int nn = n + start - 1;
      mu[n] += W_1_1[nn] * r_1_1[J_1_1[nn]] * Z_1_1_1[nn] + W_1_2[nn] * r_1_1[J_1_2[nn]] * Z_1_1_2[nn] + W_1_3[nn] * r_1_1[J_1_3[nn]] * Z_1_1_3[nn] + W_1_4[nn] * r_1_1[J_1_4[nn]] * Z_1_1_4[nn] + W_1_5[nn] * r_1_1[J_1_5[nn]] * Z_1_1_5[nn] + W_1_6[nn] * r_1_1[J_1_6[nn]] * Z_1_1_6[nn] + W_1_7[nn] * r_1_1[J_1_7[nn]] * Z_1_1_7[nn] + W_1_8[nn] * r_1_1[J_1_8[nn]] * Z_1_1_8[nn] + W_1_9[nn] * r_1_1[J_1_9[nn]] * Z_1_1_9[nn] + W_1_10[nn] * r_1_1[J_1_10[nn]] * Z_1_1_10[nn] + W_1_11[nn] * r_1_1[J_1_11[nn]] * Z_1_1_11[nn] + W_1_12[nn] * r_1_1[J_1_12[nn]] * Z_1_1_12[nn] + W_1_13[nn] * r_1_1[J_1_13[nn]] * Z_1_1_13[nn] + W_1_14[nn] * r_1_1[J_1_14[nn]] * Z_1_1_14[nn] + W_1_1[nn] * r_1_2[J_1_1[nn]] * Z_1_2_1[nn] + W_1_2[nn] * r_1_2[J_1_2[nn]] * Z_1_2_2[nn] + W_1_3[nn] * r_1_2[J_1_3[nn]] * Z_1_2_3[nn] + W_1_4[nn] * r_1_2[J_1_4[nn]] * Z_1_2_4[nn] + W_1_5[nn] * r_1_2[J_1_5[nn]] * Z_1_2_5[nn] + W_1_6[nn] * r_1_2[J_1_6[nn]] * Z_1_2_6[nn] + W_1_7[nn] * r_1_2[J_1_7[nn]] * Z_1_2_7[nn] + W_1_8[nn] * r_1_2[J_1_8[nn]] * Z_1_2_8[nn] + W_1_9[nn] * r_1_2[J_1_9[nn]] * Z_1_2_9[nn] + W_1_10[nn] * r_1_2[J_1_10[nn]] * Z_1_2_10[nn] + W_1_11[nn] * r_1_2[J_1_11[nn]] * Z_1_2_11[nn] + W_1_12[nn] * r_1_2[J_1_12[nn]] * Z_1_2_12[nn] + W_1_13[nn] * r_1_2[J_1_13[nn]] * Z_1_2_13[nn] + W_1_14[nn] * r_1_2[J_1_14[nn]] * Z_1_2_14[nn] + r_2_1[J_2[nn]] * Z_2_1[nn] + r_2_2[J_2[nn]] * Z_2_2[nn];
    }
    ptarget += normal_id_glm_lpdf(Y[start:end] | Xc[start:end], mu, b, sigma);
    return ptarget;
  }
}
data {
  int<lower=1> N;  // total number of observations
  vector[N] Y;  // response variable
  int<lower=1> K;  // number of population-level effects
  matrix[N, K] X;  // population-level design matrix
  int<lower=1> Kc;  // number of population-level effects after centering
  int grainsize;  // grainsize for threading
  // data for group-level effects of ID 1
  int<lower=1> N_1;  // number of grouping levels
  int<lower=1> M_1;  // number of coefficients per level
  array[N] int<lower=1> J_1_1;  // grouping indicator per observation
  array[N] real W_1_1;  // multi-membership weights
  array[N] int<lower=1> J_1_2;  // grouping indicator per observation
  array[N] real W_1_2;  // multi-membership weights
  array[N] int<lower=1> J_1_3;  // grouping indicator per observation
  array[N] real W_1_3;  // multi-membership weights
  array[N] int<lower=1> J_1_4;  // grouping indicator per observation
  array[N] real W_1_4;  // multi-membership weights
  array[N] int<lower=1> J_1_5;  // grouping indicator per observation
  array[N] real W_1_5;  // multi-membership weights
  array[N] int<lower=1> J_1_6;  // grouping indicator per observation
  array[N] real W_1_6;  // multi-membership weights
  array[N] int<lower=1> J_1_7;  // grouping indicator per observation
  array[N] real W_1_7;  // multi-membership weights
  array[N] int<lower=1> J_1_8;  // grouping indicator per observation
  array[N] real W_1_8;  // multi-membership weights
  array[N] int<lower=1> J_1_9;  // grouping indicator per observation
  array[N] real W_1_9;  // multi-membership weights
  array[N] int<lower=1> J_1_10;  // grouping indicator per observation
  array[N] real W_1_10;  // multi-membership weights
  array[N] int<lower=1> J_1_11;  // grouping indicator per observation
  array[N] real W_1_11;  // multi-membership weights
  array[N] int<lower=1> J_1_12;  // grouping indicator per observation
  array[N] real W_1_12;  // multi-membership weights
  array[N] int<lower=1> J_1_13;  // grouping indicator per observation
  array[N] real W_1_13;  // multi-membership weights
  array[N] int<lower=1> J_1_14;  // grouping indicator per observation
  array[N] real W_1_14;  // multi-membership weights
  // group-level predictor values
  vector[N] Z_1_1_1;
  vector[N] Z_1_1_2;
  vector[N] Z_1_1_3;
  vector[N] Z_1_1_4;
  vector[N] Z_1_1_5;
  vector[N] Z_1_1_6;
  vector[N] Z_1_1_7;
  vector[N] Z_1_1_8;
  vector[N] Z_1_1_9;
  vector[N] Z_1_1_10;
  vector[N] Z_1_1_11;
  vector[N] Z_1_1_12;
  vector[N] Z_1_1_13;
  vector[N] Z_1_1_14;
  vector[N] Z_1_2_1;
  vector[N] Z_1_2_2;
  vector[N] Z_1_2_3;
  vector[N] Z_1_2_4;
  vector[N] Z_1_2_5;
  vector[N] Z_1_2_6;
  vector[N] Z_1_2_7;
  vector[N] Z_1_2_8;
  vector[N] Z_1_2_9;
  vector[N] Z_1_2_10;
  vector[N] Z_1_2_11;
  vector[N] Z_1_2_12;
  vector[N] Z_1_2_13;
  vector[N] Z_1_2_14;
  int<lower=1> NC_1;  // number of group-level correlations
  // data for group-level effects of ID 2
  int<lower=1> N_2;  // number of grouping levels
  int<lower=1> M_2;  // number of coefficients per level
  array[N] int<lower=1> J_2;  // grouping indicator per observation
  // group-level predictor values
  vector[N] Z_2_1;
  vector[N] Z_2_2;
  int<lower=1> NC_2;  // number of group-level correlations
  int prior_only;  // should the likelihood be ignored?
}
transformed data {
  matrix[N, Kc] Xc;  // centered version of X without an intercept
  vector[Kc] means_X;  // column means of X before centering
  array[N] int seq = sequence(1, N);
  for (i in 2:K) {
    means_X[i - 1] = mean(X[, i]);
    Xc[, i - 1] = X[, i] - means_X[i - 1];
  }
}
parameters {
  vector[Kc] b;  // regression coefficients
  real Intercept;  // temporary intercept for centered predictors
  real<lower=0> sigma;  // dispersion parameter
  vector<lower=0>[M_1] sd_1;  // group-level standard deviations
  matrix[M_1, N_1] z_1;  // standardized group-level effects
  cholesky_factor_corr[M_1] L_1;  // cholesky factor of correlation matrix
  vector<lower=0>[M_2] sd_2;  // group-level standard deviations
  matrix[M_2, N_2] z_2;  // standardized group-level effects
  cholesky_factor_corr[M_2] L_2;  // cholesky factor of correlation matrix
}
transformed parameters {
  matrix[N_1, M_1] r_1;  // actual group-level effects
  // using vectors speeds up indexing in loops
  vector[N_1] r_1_1;
  vector[N_1] r_1_2;
  matrix[N_2, M_2] r_2;  // actual group-level effects
  // using vectors speeds up indexing in loops
  vector[N_2] r_2_1;
  vector[N_2] r_2_2;
  // prior contributions to the log posterior
  real lprior = 0;
  // compute actual group-level effects
  r_1 = scale_r_cor(z_1, sd_1, L_1);
  r_1_1 = r_1[, 1];
  r_1_2 = r_1[, 2];
  // compute actual group-level effects
  r_2 = scale_r_cor(z_2, sd_2, L_2);
  r_2_1 = r_2[, 1];
  r_2_2 = r_2[, 2];
  lprior += student_t_lpdf(Intercept | 3, 3.3, 2.5);
  lprior += student_t_lpdf(sigma | 3, 0, 2.5)
    - 1 * student_t_lccdf(0 | 3, 0, 2.5);
  lprior += student_t_lpdf(sd_1 | 3, 0, 2.5)
    - 2 * student_t_lccdf(0 | 3, 0, 2.5);
  lprior += lkj_corr_cholesky_lpdf(L_1 | 1);
  lprior += student_t_lpdf(sd_2 | 3, 0, 2.5)
    - 2 * student_t_lccdf(0 | 3, 0, 2.5);
  lprior += lkj_corr_cholesky_lpdf(L_2 | 1);
}
model {
  // likelihood including constants
  if (!prior_only) {
    target += reduce_sum(partial_log_lik_lpmf, seq, grainsize, Y, Xc, b, Intercept, sigma, J_1_1, W_1_1, J_1_2, W_1_2, J_1_3, W_1_3, J_1_4, W_1_4, J_1_5, W_1_5, J_1_6, W_1_6, J_1_7, W_1_7, J_1_8, W_1_8, J_1_9, W_1_9, J_1_10, W_1_10, J_1_11, W_1_11, J_1_12, W_1_12, J_1_13, W_1_13, J_1_14, W_1_14, Z_1_1_1, Z_1_1_2, Z_1_1_3, Z_1_1_4, Z_1_1_5, Z_1_1_6, Z_1_1_7, Z_1_1_8, Z_1_1_9, Z_1_1_10, Z_1_1_11, Z_1_1_12, Z_1_1_13, Z_1_1_14, Z_1_2_1, Z_1_2_2, Z_1_2_3, Z_1_2_4, Z_1_2_5, Z_1_2_6, Z_1_2_7, Z_1_2_8, Z_1_2_9, Z_1_2_10, Z_1_2_11, Z_1_2_12, Z_1_2_13, Z_1_2_14, r_1_1, r_1_2, J_2, Z_2_1, Z_2_2, r_2_1, r_2_2);
  }
  // priors including constants
  target += lprior;
  target += std_normal_lpdf(to_vector(z_1));
  target += std_normal_lpdf(to_vector(z_2));
}
generated quantities {
  // actual population-level intercept
  real b_Intercept = Intercept - dot_product(means_X, b);
  // compute group-level correlations
  corr_matrix[M_1] Cor_1 = multiply_lower_tri_self_transpose(L_1);
  vector<lower=-1,upper=1>[NC_1] cor_1;
  // compute group-level correlations
  corr_matrix[M_2] Cor_2 = multiply_lower_tri_self_transpose(L_2);
  vector<lower=-1,upper=1>[NC_2] cor_2;
  // extract upper diagonal of correlation matrix
  for (k in 1:M_1) {
    for (j in 1:(k - 1)) {
      cor_1[choose(k - 1, 2) + j] = Cor_1[j, k];
    }
  }
  // extract upper diagonal of correlation matrix
  for (k in 1:M_2) {
    for (j in 1:(k - 1)) {
      cor_2[choose(k - 1, 2) + j] = Cor_2[j, k];
    }
  }
}

